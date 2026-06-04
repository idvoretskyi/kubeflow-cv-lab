# AGENTS.md

Guidance for AI coding agents (and humans) working in **kubeflow-cv-lab**. Read
this before making changes.

## What this project is

An end-to-end computer-vision MLOps lab that runs on a GPU-enabled Kubeflow
cluster (Kubeflow **26.03** on Linode/Akamai LKE). The loop is:

> Roboflow Universe dataset → Kubeflow Pipeline (load → train YOLOv8 on GPU →
> evaluate → register) → self-hosted MLflow (tracking + registry) → KServe
> InferenceService → `supervision` visualization.

The companion infrastructure repo is `akamai-lke-gpu-cluster`
(GitHub: `idvoretskyi/linode-gpu-k8s`). This repo only contains the lab workload;
it does **not** provision the cluster.

## Repository layout

| Path | Purpose |
|---|---|
| `deploy/` | Cluster manifests (kustomize): `cv-lab` namespace, the additive SeaweedFS NetworkPolicy, Postgres, MLflow server. |
| `pipeline/` | Kubeflow Pipeline (KFP v2): `load_data → train → evaluate → register`. Source `pipeline.py` + committed compiled `pipeline.yaml`. |
| `images/` | Container images that must be built/pushed (KServe serving predictor). |
| `serving/` | KServe `InferenceService` + S3-backed `ServiceAccount`/`Secret`. |
| `notebooks/` | `supervision` visualization against the InferenceService. |
| `secrets/` | `*.example.yaml` templates only. Real secrets are git-ignored. |

## Cluster invariants — do not break these

These reflect the verified Kubeflow **26.03** layout. Code must conform to them.

- **Object store is SeaweedFS**, reachable at **`seaweedfs.kubeflow:8333`** (S3).
  Name the lab's own object-store resources, buckets, and env vars after
  `seaweedfs` / `s3` / `object-store` — never after any legacy object store.
- **S3 credentials:** SeaweedFS 26.03 runs with IAM (not anonymous), so real
  credentials are required. The lab ships its own `cv-lab` Secret
  `seaweedfs-s3-credentials` (consumed by MLflow and KServe); populate it with the
  cluster's SeaweedFS S3 credentials. Kubernetes Secrets are namespace-scoped —
  do not read the cluster's object-store Secret across namespaces.
- **The only permitted change to the `kubeflow` namespace** is one additive
  `NetworkPolicy` allowing `cv-lab → seaweedfs:8333`. Do not patch, delete, or
  re-point any upstream Kubeflow resource.
- **MLflow uses proxied artifacts** (`mlflow server --serve-artifacts
  --artifacts-destination s3://mlflow`). Training pods talk to MLflow over HTTP
  (`mlflow-artifacts:/`) and must not need direct S3 access or credentials.
- **GPU scheduling contract** for any GPU step:
  - request a GPU: `set_accelerator_type("nvidia.com/gpu")` + `set_accelerator_limit(1)`
  - tolerate the taint: `kubernetes.add_toleration(task, key="nvidia.com/gpu", operator="Exists", effect="NoSchedule")`
  - pin to the pool: `kubernetes.add_node_selector(task, "nodepool.lke/role", "gpu")`
- **Namespace:** the lab's own resources (MLflow, Postgres, KServe) live in
  `cv-lab`. Pipeline pods run in the `kubeflow` namespace.

## Conventions

- **Pipelines:** KFP v2 SDK (`kfp>=2`, `kfp-kubernetes`). Always commit the
  recompiled `pipeline/pipeline.yaml` alongside `pipeline.py` changes
  (`make compile`). CI fails on drift.
- **Manifests:** kustomize under `deploy/`. Validate with `kubeconform`.
- **Images:** the trainer step uses `ultralytics/ultralytics` as a KFP
  `base_image` with runtime `packages_to_install` — no custom trainer image. Only
  the KServe serving image is built and pushed (to `ghcr.io/idvoretskyi/...`).
- **MLflow image:** official `ghcr.io/mlflow/mlflow`; Postgres/boto3 drivers are
  `pip install`-ed at pod start (no custom MLflow image).
- **Default dataset:** Roboflow Universe *Aquarium Combined*
  (`roboflow-jvuqo/aquarium-combined`, YOLOv8 format), overridable via pipeline
  parameters.
- **Secrets:** never commit credentials or API keys. Provide `*.example.yaml`
  templates only; real files match `secrets/*.yaml` and are git-ignored.

## Build / lint / test

```bash
make venv      # virtualenv with the KFP SDK
make compile   # pipeline.py -> pipeline.yaml (commit the result)
make lint      # ruff + yamllint
make deploy    # kubectl apply -k deploy/   (needs a kubeconfig)
```

CI (`.github/workflows/ci.yml`) runs: `ruff`, `yamllint`, `kubeconform`,
`markdownlint`, and a KFP compile-drift check. Keep it green.

## Guardrails

- CI must **never** apply anything to a real cluster.
- Keep `README.md` and `AGENTS.md` consistent when invariants change.
- When a Kubeflow version bump changes the object store, networking, or auth,
  re-verify the [Cluster invariants](#cluster-invariants--do-not-break-these)
  before updating code.
