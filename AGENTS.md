# AGENTS.md

Guidance for AI coding agents (and humans) working in **kubeflow-cv-lab**. Read
this before making changes.

## What this project is

An end-to-end computer-vision MLOps lab that runs on any GPU-enabled Kubeflow
cluster (Kubeflow **26.03.1**). The loop is:

> Dataset download → Kubeflow Pipeline (load → train YOLOv8 on GPU →
> evaluate → register) → self-hosted MLflow (tracking + registry) → KServe
> InferenceService → `supervision` visualization.

This repo also ships a **portable Kubeflow installer** (`platform/`) for any
GPU-enabled Kubernetes cluster.

The companion infrastructure repo is `akamai-lke-gpu-cluster`
(GitHub: `idvoretskyi/akamai-lke-gpu-cluster`). That repo provisions the cluster and
installs the NVIDIA GPU operator; it is the de-facto tested platform for this
lab (Linode/Akamai LKE), but the lab itself is cloud-neutral.

**Reference architecture (must keep fitting):** 1× `g6-standard-2` system node
(2 vCPU / 4 GB) + 1× `g2-gpu-rtx4000a1-s` (4 vCPU / 16 GB / RTX 4000 Ada),
GPU node tainted `nvidia.com/gpu:NoSchedule`, `KF_PROFILE=minimal`. Any new
workload must state its requests and must not request a GPU unless it is a
training step.

**Cross-repo contract:**

- `akamai-lke-gpu-cluster` = pure OpenTofu cloud substrate (LKE cluster, GPU Operator, monitoring).
- `kubeflow-cv-lab` = portable ML platform + application layer (this repo).
- Cloud-specific literals belong only in `akamai-lke-gpu-cluster/tofu/locals.tf`,
  `kubeflow-cv-lab/platform/presets/lke.env` and `kubeflow-cv-lab/deploy/overlays/lke/`.

## Repository layout

| Path | Purpose |
|---|---|
| `platform/` | Portable Kubeflow installer: `install.sh` (`KF_PROFILE` = `minimal` or `full`), `uninstall.sh`, `config.env.example`, `presets/`. |
| `examples/kubeflow-pipelines/` | Hello-world + GPU smoke-test pipelines. Doubles as post-install smoke test. |
| `examples/pytorch-training/` | Kubeflow Trainer v2 GPU validation job (`TrainJob` API). Requires Kubeflow installed. |
| `deploy/` | Lab layer: `bootstrap.sh` (Profile + Secrets), `base/` (SeaweedFS NetworkPolicy, Postgres, MLflow), `overlays/lke/`. |
| `tofu/` | Optional state-tracked alternative to `make deploy`; reads the same `deploy/base/` YAML (no duplication). |
| `pipeline/` | KFP v2 pipeline `pipeline.py` + compiled `pipeline.yaml`; shared `gpu_scheduling.py` and `versions.py`. |
| `images/` | Container images that must be built/pushed (KServe serving predictor). |
| `serving/` | KServe `InferenceService` (Standard mode, CPU, `models:/…@champion` via MLflow HTTP). |
| `notebooks/` | `supervision` visualization against the InferenceService. |
| `secrets/` | `*.example.yaml` templates only. Real secrets are git-ignored. |

## Cluster invariants — do not break these

These reflect the verified Kubeflow **26.03.1** layout. Code must conform to them.

- **Object store is SeaweedFS**, reachable at **`seaweedfs.kubeflow:8333`** (S3).
  Name the lab's own object-store resources, buckets, and env vars after
  `seaweedfs` / `s3` / `object-store` — never after any legacy object store.
- **S3 credentials:** SeaweedFS runs with IAM (not anonymous). The lab keeps its
  own `cv-lab` Secret `seaweedfs-s3-credentials`, consumed only by MLflow.
  `deploy/bootstrap.sh` copies it with the operator's kubectl from upstream
  `kubeflow/mlpipeline-minio-artifact` (an upstream name; do not rename it).
  Pods must never read Secrets across namespaces.
- **SeaweedFS pod label** is `app: seaweedfs` (not `app.kubernetes.io/name`).
- **The only permitted change to the `kubeflow` namespace** is one additive
  `NetworkPolicy` allowing `cv-lab → seaweedfs:8333`. Do not patch, delete, or
  re-point any upstream Kubeflow resource.
- **MLflow uses proxied artifacts** (`mlflow server --serve-artifacts
  --artifacts-destination s3://mlflow`). Training pods talk to MLflow over HTTP
  (`mlflow-artifacts:/`) and must not need direct S3 access or credentials.
- **GPU scheduling contract** for any GPU step:
  - **Required:** request a GPU — `set_accelerator_type("nvidia.com/gpu")` + `set_accelerator_limit(1)`
  - Implemented once in `pipeline/gpu_scheduling.py` (`gpu_task` / `cpu_task`); reuse it.
  - **Recommended:** tolerate the taint — `kubernetes.add_toleration(task, key="nvidia.com/gpu", operator="Exists", effect="NoSchedule")` (no-op if nodes are untainted)
  - **GPU-node identification:** use the GPU Feature Discovery (GFD) label — `kubernetes.add_node_selector(task, "nvidia.com/gpu.present", "true")`. This label is written by the NVIDIA GPU Operator's GFD component on every GPU node on any cluster; it is vendor-neutral. The GPU resource request is the hard placement guarantee; the selector is an explicit filter. Override `GPU_NODE_SELECTOR_KEY`/`GPU_NODE_SELECTOR_VALUE` env vars to use a different label (e.g. `nodepool.lke/role=gpu` for strict LKE pool pinning), or set `GPU_NODE_SELECTOR_KEY=""` to omit the selector.
  - **Do not hardcode cloud-specific pool labels** (like `nodepool.lke/role`) in committed pipeline code; use env vars or presets instead.
- **CPU workloads may tolerate the GPU taint** (to overflow onto the GPU node in the
  2-node reference cluster) but must never request `nvidia.com/gpu`.
- **KServe** runs in `Standard` (raw Deployment) mode; the minimal profile has no Knative.
- **Namespace:** the lab's own resources (MLflow, Postgres, KServe) live in
  `cv-lab`. Pipeline pods run in the `kubeflow` namespace.

## platform/ invariants

- `platform/*.sh` and `deploy/bootstrap.sh` must be POSIX sh (not bash).
  Run `shellcheck -s sh` on them before committing.
- `KF_PROFILE=minimal` (default) is the reference install; `full` = upstream `example`.
  When bumping `KF_VERSION`, re-check that every path in the minimal resource list
  and every patched Deployment/container name still exists upstream.
- The **GPU operator is an external prerequisite** — it must be running on the
  cluster before `platform/install.sh` is called. Never install the GPU operator
  from these scripts.
- `KF_WEBHOOK_ACCESS` defaults to `auto` (runtime detection of node IPs +
  apiserver endpoints + podCIDRs). Other modes: `open`, `cidrs`, `skip`. No
  cloud-specific CIDRs in built-in defaults.
- `platform/presets/<name>.env` captures cloud-specific or cluster-specific
  overrides (e.g. `platform/presets/lke.env` for Linode LKE). Presets are
  the only place where cloud-vendor literals (CIDRs, pool labels) belong.
- `platform/config.env` is git-ignored. Only `config.env.example` is committed.

## examples/ conventions

- `examples/kubeflow-pipelines/` contains the hello-world and GPU smoke-test
  pipelines. Always commit the compiled `*.yaml` alongside any `*.py` changes.
- These pipelines follow the **GPU scheduling contract** above. The compiled
  YAML must not contain cloud-specific labels; use env var overrides for
  cluster-specific targeting.

## Conventions

- **Pipelines:** KFP v2 SDK pinned exactly in `pipeline/requirements.txt`
  (examples reuse it). Always commit recompiled YAML (`make compile`,
  `make examples-compile`). CI fails on drift.
- **Versions:** MLflow is pinned identically in `pipeline/versions.py`,
  `deploy/base/mlflow/deployment.yaml` and `images/serving/requirements.txt`.
- **Manifests:** kustomize under `deploy/`. Validate with `kubeconform`.
- **Images:** the trainer step uses `ultralytics/ultralytics` as a KFP
  `base_image` with runtime `packages_to_install` — no custom trainer image. Only
  the KServe serving image is built and pushed (to `ghcr.io/idvoretskyi/...`).
- **MLflow image:** official `ghcr.io/mlflow/mlflow`; Postgres/boto3 drivers are
  `pip install`-ed by the `setup` init container into a shared `emptyDir`, which
  also creates the `mlflow` bucket (no custom MLflow image, no separate Job).
- **Default dataset:** [COCO128](https://docs.ultralytics.com/datasets/detect/coco/)
  (128-image COCO subset, YOLOv8 format), downloaded from
  `ultralytics.com/assets/coco128.zip`. Overridable via the `dataset_url` pipeline
  parameter. The `load_data` step accepts any publicly accessible YOLOv8-format
  dataset zip URL.
- **Secrets:** never commit credentials or API keys. Provide `*.example.yaml`
  templates only; real files match `secrets/*.yaml` and are git-ignored.

## Build / lint / test

```bash
make help                          # all targets
make platform-install PRESET=lke   # Kubeflow (needs a kubeconfig)
make bootstrap                     # cv-lab Profile + Secrets
make deploy OVERLAY=lke            # Postgres + MLflow
make compile examples-compile      # pipelines -> YAML (commit the result)
make serve                         # KServe InferenceService
make lint                          # ruff + yamllint + shellcheck
make tofu-plan / tofu-apply        # optional alternative to `make deploy`
```

CI (`.github/workflows/ci.yml`) runs: `ruff`, `yamllint`, kustomize +
`kubeconform` (`deploy/`, `deploy/overlays/lke`, `serving/`), `tofu validate`,
`markdownlint`, `shellcheck -s sh`, and a KFP compile-drift check (including
examples). The serving image is built (not pushed) on PRs. Keep it green.

## Guardrails

- CI must **never** apply anything to a real cluster.
- Keep `README.md` and `AGENTS.md` consistent when invariants change.
- When a Kubeflow version bump changes the object store, networking, or auth,
  re-verify the [Cluster invariants](#cluster-invariants--do-not-break-these)
  before updating code.
