# kubeflow-cv-lab

[![CI](https://github.com/idvoretskyi/kubeflow-cv-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/idvoretskyi/kubeflow-cv-lab/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Kubeflow](https://img.shields.io/badge/Kubeflow-26.03.1-326CE5?logo=kubeflow&logoColor=white)](https://www.kubeflow.org)
[![MLflow](https://img.shields.io/badge/MLflow-3.17-0194E2?logo=mlflow&logoColor=white)](https://mlflow.org)
[![Ultralytics YOLO](https://img.shields.io/badge/Ultralytics-8.4-111F68)](https://docs.ultralytics.com)

A **reference architecture for computer-vision MLOps on Kubeflow**, sized to run
on the cheapest NVIDIA RTX 4000 Ada cluster on Akamai/Linode LKE:

> **COCO128 → Kubeflow Pipeline (load → train YOLOv8 on GPU → evaluate →
> register) → MLflow (tracking + registry) → KServe → `supervision`
> visualization.**

The lab is cloud-neutral. It also ships a portable Kubeflow installer
(`platform/`) for any GPU-enabled Kubernetes cluster; the LKE preset is the
tested reference path. The companion cluster repo is
[`akamai-lke-gpu-cluster`](https://github.com/idvoretskyi/akamai-lke-gpu-cluster).

## Reference architecture

| Node pool | Linode plan | Size | Runs |
|---|---|---|---|
| system ×1 | `g6-standard-2` | 2 vCPU / 4 GB | GPU Operator controller, monitoring, part of Kubeflow |
| gpu ×1 | `g2-gpu-rtx4000a1-s` | 4 vCPU / 16 GB / 1× RTX 4000 Ada (20 GB) | YOLO training; overflow of CPU workloads |

That is the smallest RTX 4000 Ada layout: about **$0.52/h for the GPU node plus
$24/month for the system node** (Linode list prices). The GPU node is
tainted `nvidia.com/gpu=present:NoSchedule`.

To fit two nodes:

- **Kubeflow `KF_PROFILE=minimal`** (default) installs only what the lab uses:
  Istio, Dex, Dashboard, Profiles, Pipelines (+ SeaweedFS), Trainer v2, KServe in
  Standard (raw Deployment) mode. It has no Knative, Katib, Notebooks, Spark or
  Model Registry, and trimmed requests bring the control plane to ~0.9 vCPU /
  ~2.7 GiB.
- **CPU-only workloads tolerate the GPU taint** (Kubeflow control plane, MLflow,
  Postgres, CPU pipeline steps, the predictor). They can use the GPU node's
  spare CPU and memory but **never request a GPU**. Only the `train` step takes
  the GPU, and it releases it when training ends.
- **The predictor runs on CPU**, so the GPU stays free for training.

| Component | Version |
|---|---|
| Kubeflow manifests | 26.03.1 (KFP SDK 2.17.0, KServe 0.18, Trainer v2) |
| Object store | SeaweedFS (Kubeflow upstream default) |
| MLflow | 3.17.0 + PostgreSQL 18 |
| Ultralytics | 8.4.174 (YOLOv8n by default) |
| Serving image | Python 3.12, PyTorch 2.14.1 (CPU), KServe SDK 0.18 |

## Architecture

```text
                       cv-lab namespace                         kubeflow namespace
  ┌───────────────────────────────────────────┐      ┌──────────────────────────────┐
  │  mlflow (--serve-artifacts) ──────────────────S3──▶  seaweedfs (S3 :8333)         │
  │     │  backend store                        │      │  (+ additive NetworkPolicy)  │
  │     ▼                                       │      │                              │
  │  postgres (PVC)                             │      │  Kubeflow Pipelines          │
  │                                             │      │   load → train(GPU) →        │
  │  KServe InferenceService (CPU predictor)    │      │   evaluate → register        │
  └─────────────▲─────────────────────────────┘      └──────────────┬───────────────┘
                └──── HTTP: models:/yolov8-coco128@champion ◀────────┘ mlflow-artifacts:/
```

Training and serving pods only talk to MLflow over HTTP. Only MLflow holds S3
credentials.

## Quick start (five commands)

Prerequisites: a cluster with the **NVIDIA GPU Operator** running (for example
from `akamai-lke-gpu-cluster`) and a default StorageClass, plus `kubectl`,
`kustomize`, `git` and Python 3.11+ on your workstation.

```bash
make platform-install PRESET=lke   # 1. Kubeflow 26.03.1, minimal profile (~10–20 min)
make bootstrap                     # 2. cv-lab Profile + Postgres/SeaweedFS Secrets
make deploy OVERLAY=lke            # 3. Postgres + MLflow (creates the S3 bucket itself)

make compile                       # 4. pipeline/pipeline.yaml, then run it in the UI:
make port-forward-dashboard        #    http://localhost:8080 (user@example.com / 12341234)
                                   #    Pipelines → Upload → pipeline/pipeline.yaml → Create run

make serve                         # 5. KServe InferenceService for the @champion model
```

Then look at the results:

```bash
make port-forward-mlflow      # http://localhost:5000 — runs, metrics, registry
make port-forward-predictor   # then run notebooks/explore.ipynb locally
```

On a cluster other than LKE, drop `PRESET=lke` / `OVERLAY=lke`. Each later
training run moves the `champion` alias. To serve the new model, run
`kubectl -n cv-lab rollout restart deploy/yolov8-coco128-predictor`.

### Smoke tests (optional)

```bash
make examples-compile   # upload examples/kubeflow-pipelines/{hello,gpu}_pipeline.yaml
make -C examples/pytorch-training apply wait logs clean   # Trainer v2 GPU TrainJob
```

## Configuration knobs

| What | Where |
|---|---|
| Kubeflow version / profile / webhook mode | `platform/config.env` or `platform/presets/*.env` — see [`platform/README.md`](platform/README.md) |
| Postgres StorageClass | `deploy/overlays/<cloud>/` (kustomize) or `tofu/tofu.tfvars` |
| Dataset, epochs, image size, model variant | pipeline run parameters — see [`pipeline/README.md`](pipeline/README.md) |
| GPU node selector / taint | compile-time env vars — see `pipeline/gpu_scheduling.py` |
| Runtime versions | `pipeline/versions.py`, `deploy/base/mlflow/deployment.yaml`, `images/serving/` |

## Repository layout

```text
kubeflow-cv-lab/
├── platform/            # Kubeflow installer (POSIX sh): install.sh, uninstall.sh, presets/
├── deploy/              # lab layer (kustomize): bootstrap.sh, base/, overlays/lke/
├── tofu/                # optional state-tracked alternative to `make deploy` (same YAML)
├── pipeline/            # KFP v2 pipeline + shared gpu_scheduling.py / versions.py
├── images/serving/      # KServe custom predictor image (CPU)
├── serving/             # KServe InferenceService
├── notebooks/           # supervision visualization
├── examples/            # KFP hello/GPU smoke tests, Trainer v2 GPU TrainJob
└── secrets/             # *.example.yaml templates only
```

## Cross-repo contract

| Layer | Repo | Manages |
|---|---|---|
| Cloud substrate | [`akamai-lke-gpu-cluster`](https://github.com/idvoretskyi/akamai-lke-gpu-cluster) | LKE cluster, GPU Operator, monitoring (OpenTofu) |
| ML platform + application | this repo | Kubeflow installer, MLflow + Postgres, pipelines, KServe |

Cloud-specific literals live only in `akamai-lke-gpu-cluster/tofu/locals.tf`,
`platform/presets/lke.env` and `deploy/overlays/lke/`.

## Upgrading an existing deployment

- **PostgreSQL 16 → 18:** the data directory format changed. Before you run
  `make deploy` on an existing install, dump the database (`pg_dump`) and delete
  the old PVC, then restore. A fresh MLflow database needs no action.
- **Tofu users:** resource addresses changed. `moved` blocks in `tofu/main.tf`
  migrate the state automatically on the next `tofu apply`.
- **Serving:** the predictor now loads `models:/yolov8-coco128@champion`.
  Re-run the pipeline once, or set the alias in the MLflow UI.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

[Kubeflow](https://www.kubeflow.org/), [MLflow](https://mlflow.org/),
[KServe](https://kserve.github.io/website/), [Ultralytics](https://docs.ultralytics.com/),
and Roboflow [`supervision`](https://supervision.roboflow.com/).
