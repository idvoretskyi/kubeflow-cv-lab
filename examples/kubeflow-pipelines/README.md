# Kubeflow Pipelines — demo pipelines

Two small pipelines that validate Kubeflow Pipelines on the cluster, including
the dedicated-GPU scheduling contract.

| Pipeline | File | What it shows |
|---|---|---|
| Hello World | [`hello_pipeline.py`](hello_pipeline.py) | CPU-only 2-step pipeline; steps run on the **system pool** |
| GPU smoke test | [`gpu_pipeline.py`](gpu_pipeline.py) | A step that requests a GPU, tolerates the GPU taint, and runs `nvidia-smi` on the **dedicated GPU pool** |

The compiled IR (`hello_pipeline.yaml`, `gpu_pipeline.yaml`) is committed for
convenience — upload straight to the Kubeflow dashboard without installing the SDK.

## Why the GPU pipeline needs extra config

GPU nodes are tainted `nvidia.com/gpu=present:NoSchedule` so they stay reserved
for GPU work. A GPU pipeline step must (see `gpu_pipeline.py`):

1. request a GPU — `task.set_accelerator_type("nvidia.com/gpu")` + `set_accelerator_limit(1)`
2. tolerate the taint — `kubernetes.add_toleration(task, key="nvidia.com/gpu", operator="Exists", effect="NoSchedule")`
3. optionally pin to the pool — `kubernetes.add_node_selector(task, "nodepool.lke/role", "gpu")`

CPU steps need none of this: without a toleration they simply cannot land on the
GPU nodes, so they stay on the system pool automatically.

## Prerequisites

- Kubeflow installed (`make platform-install` from the repo root).
- NVIDIA GPU operator running on the cluster (for the GPU pipeline).
- `kubectl` pointed at the cluster.
- For (re)compiling or submitting from Python: `make venv`.

## Compile

The committed `*.yaml` are already up to date. To regenerate:

```bash
make venv      # one-time: create .venv with kfp + kfp-kubernetes
make compile   # hello_pipeline.py -> hello_pipeline.yaml, etc.
```

Or from the repo root:

```bash
make examples-compile
```

## Run

Port-forward the Pipelines UI:

```bash
kubectl -n kubeflow port-forward svc/ml-pipeline-ui 8080:80
# Open http://localhost:8080 -> Pipelines -> Upload pipeline -> pick a *.yaml,
# then Create run.
```

Or submit from Python against the in-cluster API:

```bash
kubectl -n kubeflow port-forward svc/ml-pipeline 8888:8888 &
.venv/bin/python - <<'PY'
from kfp.client import Client
c = Client(host="http://localhost:8888")
run = c.create_run_from_pipeline_package(
    "gpu_pipeline.yaml",      # or hello_pipeline.yaml
    arguments={},
    run_name="gpu-smoke-test",
)
print("submitted:", run.run_id)
PY
```

> Multi-user Kubeflow runs behind Istio/Dex auth; when submitting through the
> ingress gateway you must pass an auth session cookie. Port-forwarding directly
> to `ml-pipeline` / `ml-pipeline-ui` (as above) is the simplest path for a
> quick smoke test.

## Verify

```bash
# Hello-world steps land on the system pool:
kubectl get pods -A -o wide | grep -E 'hello|say-hello|shout'

# GPU step lands on a GPU node and sees the GPU:
kubectl get pods -A -o wide | grep nvidia-smi
kubectl logs <nvidia-smi-pod> -n <namespace>   # should print the GPU table
```
