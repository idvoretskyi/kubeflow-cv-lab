# kubeflow-cv-lab

[![CI](https://github.com/idvoretskyi/kubeflow-cv-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/idvoretskyi/kubeflow-cv-lab/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Kubeflow](https://img.shields.io/badge/Kubeflow-26.03-326CE5?logo=kubeflow&logoColor=white)](https://www.kubeflow.org)
[![MLflow](https://img.shields.io/badge/MLflow-tracking%20%2B%20registry-0194E2?logo=mlflow&logoColor=white)](https://mlflow.org)
[![Ultralytics YOLO](https://img.shields.io/badge/Ultralytics-YOLOv8-111F68)](https://docs.ultralytics.com)

A hands-on, newcomer-friendly **computer-vision MLOps lab** that runs entirely on a
GPU-enabled Kubeflow cluster. It wires together the open-source Roboflow stack,
Kubeflow Pipelines, MLflow, and KServe into a single end-to-end loop:

> **Roboflow Universe dataset → Kubeflow Pipeline (load → train YOLOv8 on GPU →
> evaluate → register) → self-hosted MLflow (tracking + registry) →
> KServe InferenceService → `supervision` visualization.**

It is designed to run on top of the GPU LKE cluster from
[`akamai-lke-gpu-cluster`](https://github.com/idvoretskyi/linode-gpu-k8s)
(Kubeflow **26.03**), but the manifests are generic enough for any Kubeflow 26.03
install that uses the default SeaweedFS object store.

> **Status:** scaffolding. The cluster manifests, pipeline, serving image, and
> notebook are added in later phases (see [Roadmap](#roadmap)). This first drop is
> the repository baseline (docs, CI, conventions).

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
| Dataset | `roboflow` SDK / Universe | pipeline step |
| Orchestration | Kubeflow Pipelines (KFP v2) | kubeflow ns |
| Training | Ultralytics YOLOv8 (CUDA) | GPU pool (taint toleration) |
| Tracking + registry | MLflow (self-hosted) | `cv-lab` ns |
| Backend store | PostgreSQL + PVC | `cv-lab` ns |
| Artifacts | SeaweedFS S3 (`seaweedfs.kubeflow:8333`) | kubeflow ns |
| Serving | KServe `InferenceService` | `cv-lab` ns |
| Visualization | `supervision` | notebook |

## Cluster assumptions (Kubeflow 26.03)

This lab targets the object-store and networking layout shipped in Kubeflow
**26.03**:

- **Object store:** SeaweedFS is the default store, reachable in-cluster at
  **`seaweedfs.kubeflow:8333`** (S3). There is **no MinIO** — only a Service named
  `minio-service` kept for KFP backward compatibility, backed by SeaweedFS.
- **S3 credentials:** SeaweedFS runs with `-iam` and configures an admin user from
  the existing `mlpipeline-minio-artifact` Secret (`accesskey=minio`,
  `secretkey=minio123`). MLflow and KServe reuse those credentials.
- **Cross-namespace access:** SeaweedFS is guarded by a `NetworkPolicy` that only
  admits `kubeflow-profile` namespaces, `istio-system`, and same-namespace pods on
  port `8333`. The lab adds **one** additive `NetworkPolicy` so the `cv-lab`
  namespace can reach SeaweedFS. This is the **only** modification made to the
  `kubeflow` namespace.
- **GPU scheduling:** GPU nodes are tainted `nvidia.com/gpu=present:NoSchedule` and
  labelled `nodepool.lke/role=gpu`. The training step adds the matching toleration,
  node selector, and a GPU resource request.

## Repository layout

```text
kubeflow-cv-lab/
├── README.md            # this file
├── AGENTS.md            # guide for AI agents and contributors
├── LICENSE              # MIT
├── Makefile             # venv / compile / lint / deploy helpers
├── deploy/              # cluster manifests: namespace, NetworkPolicy, Postgres, MLflow
├── pipeline/            # Kubeflow Pipeline (KFP v2): load → train → evaluate → register
├── images/              # container images (KServe serving predictor)
├── serving/             # KServe InferenceService + S3 service account
├── notebooks/           # supervision visualization notebook
└── secrets/             # *.example.yaml templates (real secrets are git-ignored)
```

## Quick start

> Requires the manifests/pipeline added in later phases. The flow will be:

```bash
# 1. Deploy the lab (namespace, NetworkPolicy, Postgres, MLflow)
kubectl apply -k deploy/

# 2. Create secrets from the templates in secrets/
cp secrets/roboflow-api-key.example.yaml secrets/roboflow-api-key.yaml
# edit, then: kubectl apply -f secrets/roboflow-api-key.yaml

# 3. Compile and upload the pipeline
make venv && make compile
kubectl -n kubeflow port-forward svc/ml-pipeline-ui 8080:80
# open http://localhost:8080 → Pipelines → Upload → pipeline/pipeline.yaml → Create run

# 4. Watch experiments
kubectl -n cv-lab port-forward svc/mlflow 5000:5000   # http://localhost:5000

# 5. Serve the trained model and visualize predictions
kubectl apply -f serving/
# run notebooks/explore.ipynb
```

## Roadmap

- [x] **Phase 1** — repository baseline (docs, CI, conventions)
- [ ] **Phase 2** — `deploy/` manifests (namespace, NetworkPolicy, Postgres, MLflow)
- [ ] **Phase 3** — `pipeline/` Kubeflow Pipeline (load → train → evaluate → register)
- [ ] **Phase 4** — `images/serving` + `serving/` KServe InferenceService
- [ ] **Phase 5** — `notebooks/explore.ipynb` (supervision visualization)

## License

MIT — see [LICENSE](LICENSE).

## Author

Ihor Dvoretskyi ([@idvoretskyi](https://github.com/idvoretskyi))

## Acknowledgments

- [Kubeflow](https://www.kubeflow.org/) community
- [Roboflow](https://roboflow.com/) open-source CV stack (`supervision`, `inference`, `roboflow`)
- [Ultralytics](https://docs.ultralytics.com/) YOLO
- [MLflow](https://mlflow.org/) and [KServe](https://kserve.github.io/website/) projects
