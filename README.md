# kubeflow-cv-lab

[![CI](https://github.com/idvoretskyi/kubeflow-cv-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/idvoretskyi/kubeflow-cv-lab/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Kubeflow](https://img.shields.io/badge/Kubeflow-26.03-326CE5?logo=kubeflow&logoColor=white)](https://www.kubeflow.org)
[![MLflow](https://img.shields.io/badge/MLflow-tracking%20%2B%20registry-0194E2?logo=mlflow&logoColor=white)](https://mlflow.org)
[![Ultralytics YOLO](https://img.shields.io/badge/Ultralytics-YOLOv8-111F68)](https://docs.ultralytics.com)

A hands-on, newcomer-friendly **computer-vision MLOps lab** that runs on a
GPU-enabled Kubeflow cluster. It wires together Kubeflow Pipelines, MLflow,
and KServe into a single end-to-end loop:

> **COCO128 dataset → Kubeflow Pipeline (load → train YOLOv8 on GPU →
> evaluate → register) → self-hosted MLflow (tracking + registry) →
> KServe InferenceService → `supervision` visualization.**

This repo also ships a **portable Kubeflow installer** (`platform/`) that works
on any conformant GPU-enabled Kubernetes cluster. Tested on Linode/Akamai LKE
with Kubeflow **26.03**; an LKE preset (`platform/presets/lke.env`) is included
for that path. The companion cluster-provisioning repo is
[`akamai-lke-gpu-cluster`](https://github.com/idvoretskyi/linode-gpu-k8s).

> **Status:** all five phases complete. The platform installer, cluster
> manifests, Kubeflow Pipeline, KServe serving image, and visualization notebook
> are all implemented and verified end-to-end on Kubeflow 26.03 on LKE.

## Architecture

```text
                       cv-lab namespace                         kubeflow namespace
  ┌───────────────────────────────────────────┐      ┌──────────────────────────────┐
  │  mlflow (server, --serve-artifacts) ──────────S3──▶  seaweedfs (S3 :8333)         │
  │     │  backend-store                        │      │   default object store       │
  │     ▼                                        │      │   (+ additive NetworkPolicy) │
  │  postgres (PVC)                              │      │                              │
  │                                              │      │  Kubeflow Pipelines API      │
  │  KServe InferenceService (YOLO predictor) ───────S3─┘  (runs train pods on GPU)    │
  └───────────────────────────────────────────┘      └──────────────────────────────┘
        ▲ HTTP (mlflow-artifacts:/)                          ▲ scheduled w/ GPU taint
        └──────────── train pod logs metrics/model ──────────┘  toleration + nodeSelector
```

| Concern | Tool | Where |
|---|---|---|
| Dataset | [COCO128](https://docs.ultralytics.com/datasets/detect/coco/) (overridable via `dataset_url`) | pipeline step |
| Orchestration | Kubeflow Pipelines (KFP v2) | kubeflow ns |
| Training | Ultralytics YOLOv8 (CUDA) | GPU pool (taint toleration) |
| Tracking + registry | MLflow (self-hosted) | `cv-lab` ns |
| Backend store | PostgreSQL + PVC | `cv-lab` ns |
| Artifacts | SeaweedFS S3 (`seaweedfs.kubeflow:8333`) | kubeflow ns |
| Serving | KServe `InferenceService` | `cv-lab` ns |
| Visualization | `supervision` | notebook |

## Prerequisites

| Requirement | Notes |
|---|---|
| Kubernetes cluster | Any distribution with GPU nodes |
| **NVIDIA GPU operator** | Must be running before `make platform-install`; see [GPU operator docs](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html) or use [`akamai-lke-gpu-cluster`](https://github.com/idvoretskyi/linode-gpu-k8s) |
| Default `StorageClass` | Required for Kubeflow and lab PVCs |
| `kubectl`, `kustomize`, `git` | For the platform installer |
| Python 3.11+ | For pipeline compilation |

## Platform (Kubeflow)

The `platform/` directory contains a portable Kubeflow installer that works on
any GPU-enabled Kubernetes cluster.

```bash
# Optional: configure for your cluster (auto-detection works on most clusters)
cp platform/config.env.example platform/config.env
$EDITOR platform/config.env

# For Linode/Akamai LKE, use the bundled preset instead:
# PRESET=lke make platform-install

# Install Kubeflow 26.03
make platform-install

# Access the Central Dashboard
kubectl port-forward -n istio-system svc/istio-ingressgateway 8080:80
# http://localhost:8080  (default: user@example.com / 12341234)
```

See [`platform/README.md`](platform/README.md) for full documentation, including
webhook access modes and how to use or add presets.

## Deploy order (full lab)

```bash
# 1. Provision a GPU Kubernetes cluster (e.g. with akamai-lke-gpu-cluster)
#    and install the NVIDIA GPU operator.

# 2. Install Kubeflow
make platform-install

# 3. Deploy the lab (namespace, NetworkPolicy, Postgres, MLflow)
kubectl apply -k deploy/

# 4. Create secrets from the templates
cp secrets/seaweedfs-s3-credentials.example.yaml secrets/seaweedfs-s3-credentials.yaml
# edit, then: kubectl apply -f secrets/seaweedfs-s3-credentials.yaml -n cv-lab
cp secrets/roboflow-api-key.example.yaml secrets/roboflow-api-key.yaml
# edit, then: kubectl apply -f secrets/roboflow-api-key.yaml -n kubeflow

# 5. Compile and upload the pipeline
make venv && make compile
kubectl -n kubeflow port-forward svc/ml-pipeline-ui 8080:80
# http://localhost:8080 → Pipelines → Upload → pipeline/pipeline.yaml → Create run

# 6. Watch experiments
kubectl -n cv-lab port-forward svc/mlflow 5000:5000   # http://localhost:5000

# 7. Serve the trained model and visualize predictions
kubectl apply -f serving/
# run notebooks/explore.ipynb
```

## Smoke test

Before running the full lab pipeline, validate Kubeflow with the bundled demo
pipelines:

```bash
make examples-compile
kubectl -n kubeflow port-forward svc/ml-pipeline-ui 8080:80
# Upload examples/kubeflow-pipelines/hello_pipeline.yaml and run it.
# Then upload gpu_pipeline.yaml — it should run nvidia-smi on the GPU pool.
```

See [`examples/kubeflow-pipelines/README.md`](examples/kubeflow-pipelines/README.md).

## Cluster assumptions (Kubeflow 26.03)

- **Object store:** SeaweedFS is the default store, reachable in-cluster at
  **`seaweedfs.kubeflow:8333`** (S3).
- **S3 credentials:** SeaweedFS runs its S3 gateway with IAM enabled. The lab
  keeps a matching set in its own `cv-lab` Secret — populate it with your
  cluster's object-store credentials (see [`secrets/`](secrets/)).
- **Cross-namespace access:** the lab adds one additive `NetworkPolicy` so the
  `cv-lab` namespace can reach SeaweedFS. This is the **only** modification made
  to the `kubeflow` namespace.
- **GPU scheduling:** GPU nodes carry the `nvidia.com/gpu` taint. The training
  step adds the matching toleration and identifies GPU nodes via the GPU Feature
  Discovery (GFD) label `nvidia.com/gpu.present=true`, which the NVIDIA GPU
  Operator sets on every GPU node regardless of cloud provider.

## Repository layout

```text
kubeflow-cv-lab/
├── README.md            # this file
├── AGENTS.md            # guide for AI agents and contributors
├── LICENSE              # MIT
├── Makefile             # venv / compile / lint / deploy / platform / tofu helpers
├── platform/            # portable Kubeflow installer (install.sh, uninstall.sh, config)
├── examples/
│   ├── kubeflow-pipelines/  # hello-world + GPU smoke-test pipelines
│   └── pytorch-training/    # Kubeflow Trainer v2 (TrainJob) GPU validation job
├── deploy/              # cluster manifests: namespace, NetworkPolicy, Postgres, MLflow
├── tofu/                # OpenTofu module: MLflow + Postgres (lab-local platform layer)
├── pipeline/            # Kubeflow Pipeline (KFP v2): load → train → evaluate → register
├── images/              # container images (KServe serving predictor)
├── serving/             # KServe InferenceService + S3 service account
├── notebooks/           # supervision visualization notebook
└── secrets/             # *.example.yaml templates (real secrets are git-ignored)
```

## Cross-repo contract

| Layer | Repo | Manages |
|---|---|---|
| Cloud substrate | [`akamai-lke-gpu-cluster`](https://github.com/idvoretskyi/linode-gpu-k8s) | LKE cluster, GPU Operator, monitoring (OpenTofu) |
| ML platform + application | this repo (`kubeflow-cv-lab`) | Kubeflow installer, MLflow+Postgres (OpenTofu), KServe, pipelines |

Cloud-specific literals live only in:
- `akamai-lke-gpu-cluster/tofu/locals.tf` — `nodepool.lke/role` label
- `kubeflow-cv-lab/platform/presets/lke.env` — LKE-specific webhook CIDRs
- `kubeflow-cv-lab/tofu/tofu.tfvars` (git-ignored) — `postgres_storage_class`

## Roadmap

- [x] **Phase 0** — platform installer (`platform/`) + demo pipelines (`examples/`)
- [x] **Phase 1** — repository baseline (docs, CI, conventions)
- [x] **Phase 2** — `deploy/` manifests (namespace, NetworkPolicy, Postgres, MLflow)
- [x] **Phase 3** — `pipeline/` Kubeflow Pipeline (load → train → evaluate → register)
- [x] **Phase 4** — `images/serving` + `serving/` KServe InferenceService
- [x] **Phase 5** — `notebooks/explore.ipynb` (supervision visualization)

## License

MIT — see [LICENSE](LICENSE).

## Author

Ihor Dvoretskyi ([@idvoretskyi](https://github.com/idvoretskyi))

## Acknowledgments

- [Kubeflow](https://www.kubeflow.org/) community
- [Roboflow](https://roboflow.com/) open-source CV stack (`supervision`, `inference`, `roboflow`)
- [Ultralytics](https://docs.ultralytics.com/) YOLO
- [MLflow](https://mlflow.org/) and [KServe](https://kserve.github.io/website/) projects
