"""Kubeflow Pipeline v2: YOLOv8 training on a YOLOv8-format dataset.

Stages
------
  load_data  — download dataset zip from a URL; patch data.yaml paths
  train      — train yolov8n.pt on a GPU node; log to MLflow (proxied artifacts)
  evaluate   — run val on best.pt; emit mAP50 / mAP50-95
  register   — register the model in the MLflow Model Registry

Default dataset: COCO128 (128-image COCO subset, ultralytics CDN).
Override via the ``dataset_url`` pipeline parameter.

GPU scheduling follows the shared contract in ``gpu_scheduling.py``
(see that module for the compile-time env overrides). Pinned runtime versions
live in ``versions.py``.

Sized for the reference cluster: one RTX 4000 Ada node with 4 vCPU / 16 GB
(Linode ``g2-gpu-rtx4000a1-s``).

Compile:
    python pipeline/pipeline.py    # writes pipeline/pipeline.yaml
Or:
    make compile
"""

import pathlib

from kfp import compiler, dsl, kubernetes

from gpu_scheduling import cpu_task, gpu_task
from versions import MLFLOW_VERSION, PYTHON_IMAGE, ULTRALYTICS_IMAGE

_MLFLOW = f"mlflow=={MLFLOW_VERSION}"


# ---------------------------------------------------------------------------
# Step 1: load_data
# ---------------------------------------------------------------------------
@dsl.component(
    base_image=PYTHON_IMAGE,
    packages_to_install=["requests", "pyyaml"],
)
def load_data(
    dataset_url: str,
    dataset_yaml_url: str,
    dataset: dsl.Output[dsl.Dataset],
) -> None:
    """Download a YOLOv8-format dataset zip from a URL and unpack it.

    Some dataset zips (e.g. ultralytics/coco128.zip) do not bundle a
    ``data.yaml`` because it is included in the ultralytics Python package
    instead.  Supply ``dataset_yaml_url`` to fetch the yaml separately; it
    will be written into the extracted dataset root so that YOLOv8 can find
    it.  Leave ``dataset_yaml_url`` empty if the zip already contains a
    ``data.yaml``.
    """
    import pathlib
    import shutil
    import tempfile
    import zipfile

    import requests
    import yaml

    # Download the zip.
    with tempfile.TemporaryDirectory() as tmp:
        zip_path = pathlib.Path(tmp) / "dataset.zip"
        print(f"Downloading {dataset_url} ...")
        with requests.get(dataset_url, stream=True, timeout=300) as r:
            r.raise_for_status()
            total = int(r.headers.get("content-length", 0))
            downloaded = 0
            with open(zip_path, "wb") as f:
                for chunk in r.iter_content(chunk_size=1 << 20):
                    f.write(chunk)
                    downloaded += len(chunk)
        print(f"Downloaded {downloaded:,} bytes (expected {total:,})")

        if not zipfile.is_zipfile(zip_path):
            preview = zip_path.read_bytes()[:200]
            raise RuntimeError(f"Downloaded file is not a zip. Preview: {preview}")

        # Extract to output path.
        out_dir = pathlib.Path(dataset.path)
        if out_dir.exists():
            shutil.rmtree(out_dir)
        out_dir.mkdir(parents=True)
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(out_dir)
        print(f"Extracted to {out_dir}")

    # Locate or fetch data.yaml.
    data_yamls = list(out_dir.rglob("data.yaml"))
    if not data_yamls and dataset_yaml_url:
        # Zip didn't include data.yaml — fetch it and place it at the dataset root.
        # For nested zips (e.g. coco128/), place next to the images/ dir.
        images_dirs = list(out_dir.rglob("images"))
        yaml_parent = images_dirs[0].parent if images_dirs else out_dir
        dest_yaml = yaml_parent / "data.yaml"
        print(f"Fetching data.yaml from {dataset_yaml_url} → {dest_yaml}")
        resp = requests.get(dataset_yaml_url, timeout=30)
        resp.raise_for_status()
        dest_yaml.write_bytes(resp.content)
        data_yamls = [dest_yaml]

    if not data_yamls:
        raise FileNotFoundError(
            f"data.yaml not found in zip and dataset_yaml_url is empty. "
            f"Contents: {list(out_dir.rglob('*'))[:20]}"
        )

    # Patch 'path' to the absolute dataset root so YOLOv8 can resolve
    # train/val image paths regardless of where the zip was extracted.
    data_yaml_path = data_yamls[0]
    dataset_root = str(data_yaml_path.parent.resolve())

    with open(data_yaml_path) as f:
        cfg = yaml.safe_load(f)
    cfg["path"] = dataset_root
    with open(data_yaml_path, "w") as f:
        yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)

    print(f"data.yaml patched: path={dataset_root}")
    print(f"Dataset ready at {out_dir}")


# ---------------------------------------------------------------------------
# Step 2: train
# ---------------------------------------------------------------------------
@dsl.component(
    base_image=ULTRALYTICS_IMAGE,
    packages_to_install=[_MLFLOW],
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
            workers=2,  # /dev/shm is a 2 GiB memory-backed emptyDir (see pipeline)
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
    base_image=ULTRALYTICS_IMAGE,
    packages_to_install=[_MLFLOW],
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

    # Log straight to the training run (no active-run/experiment state needed).
    client = mlflow.MlflowClient()
    client.log_metric(run_id, "val/mAP50", map50)
    client.log_metric(run_id, "val/mAP50-95", map50_95)

    return map50_95


# ---------------------------------------------------------------------------
# Step 4: register
# ---------------------------------------------------------------------------
@dsl.component(
    base_image=PYTHON_IMAGE,
    packages_to_install=[_MLFLOW],
)
def register(
    run_id: str,
    registered_model_name: str,
    mlflow_tracking_uri: str,
    map50_95: float,
) -> str:
    """Register the model, tag it with mAP50-95 and move the ``champion`` alias.

    KServe serves ``models:/<name>@champion``, so every successful run is
    picked up on the next predictor restart without editing manifests.
    """
    import time

    import mlflow
    from mlflow import MlflowClient

    mlflow.set_tracking_uri(mlflow_tracking_uri)
    client = MlflowClient()

    # MLflow 3.x removed the LoggedModel lookup from mlflow.register_model()
    # for runs:/ URIs unless mlflow.log_model() was used during training.
    # Use MlflowClient.create_model_version() directly with the artifact URI
    # so that any artifact logged via mlflow.log_artifacts() can be registered.
    run = client.get_run(run_id)
    artifact_uri = f"{run.info.artifact_uri}/weights"

    try:
        client.create_registered_model(registered_model_name)
    except mlflow.exceptions.MlflowException:
        pass  # model already exists — create a new version below

    mv = client.create_model_version(
        name=registered_model_name,
        source=artifact_uri,
        run_id=run_id,
    )

    for _ in range(30):
        mv = client.get_model_version(registered_model_name, mv.version)
        if mv.status == "READY":
            break
        time.sleep(2)

    print(f"Registered: {registered_model_name} v{mv.version}  (run {run_id})")
    print(f"mAP50-95: {map50_95:.4f}")

    client.set_model_version_tag(
        registered_model_name, str(mv.version), "mAP50-95", f"{map50_95:.4f}"
    )
    client.set_registered_model_alias(registered_model_name, "champion", str(mv.version))

    return f"models:/{registered_model_name}/{mv.version}"


# ---------------------------------------------------------------------------
# Pipeline definition
# ---------------------------------------------------------------------------
@dsl.pipeline(
    name="yolov8-training",
    description=(
        "Dataset download → YOLOv8 GPU training → MLflow tracking & registry → "
        "model URI for KServe serving."
    ),
)
def yolov8_pipeline(
    dataset_url: str = "https://ultralytics.com/assets/coco128.zip",
    dataset_yaml_url: str = (
        "https://raw.githubusercontent.com/ultralytics/ultralytics"
        "/main/ultralytics/cfg/datasets/coco128.yaml"
    ),
    model_variant: str = "yolov8n.pt",
    epochs: int = 10,
    imgsz: int = 640,
    mlflow_tracking_uri: str = "http://mlflow.cv-lab:5000",
    experiment_name: str = "coco128-yolov8",
    registered_model_name: str = "yolov8-coco128",
) -> None:
    load_task = cpu_task(
        load_data(dataset_url=dataset_url, dataset_yaml_url=dataset_yaml_url)
    )

    train_task = gpu_task(
        train(
            dataset=load_task.outputs["dataset"],
            model_variant=model_variant,
            epochs=epochs,
            imgsz=imgsz,
            mlflow_tracking_uri=mlflow_tracking_uri,
            experiment_name=experiment_name,
        )
    )
    # Fits g2-gpu-rtx4000a1-s (4 vCPU / 16 GB) next to the GPU operator daemons.
    train_task.set_cpu_request("2").set_memory_request("6Gi").set_memory_limit("12Gi")
    kubernetes.empty_dir_mount(
        train_task, volume_name="dshm", mount_path="/dev/shm", medium="Memory", size_limit="2Gi"
    )

    # Validation runs on CPU so the GPU is released as soon as training ends.
    eval_task = cpu_task(
        evaluate(
            dataset=load_task.outputs["dataset"],
            model_dir=train_task.outputs["model_dir"],
            mlflow_tracking_uri=mlflow_tracking_uri,
            run_id=train_task.outputs["Output"],
        )
    )
    eval_task.set_cpu_request("1").set_memory_request("2Gi").set_memory_limit("4Gi")

    cpu_task(
        register(
            run_id=train_task.outputs["Output"],
            registered_model_name=registered_model_name,
            mlflow_tracking_uri=mlflow_tracking_uri,
            map50_95=eval_task.outputs["Output"],
        )
    )


# ---------------------------------------------------------------------------
# Compile when run directly
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    out = pathlib.Path(__file__).parent / "pipeline.yaml"
    compiler.Compiler().compile(pipeline_func=yolov8_pipeline, package_path=str(out))
    print(f"Compiled → {out}")
