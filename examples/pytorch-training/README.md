# PyTorch GPU Training Example (Kubeflow Trainer v2)

A minimal GPU training job for validating the **Kubeflow Training Operator** and
NVIDIA GPU stack. Uses a 3-layer fully-connected network (784 → 256 → 128 → 10)
trained on synthetic MNIST-sized data for 200 steps via the Trainer v2 `TrainJob`
API.

## Prerequisites

- **Kubeflow installed** — run `make platform-install` (or `PRESET=lke make platform-install` for LKE).
  The installer applies the `ClusterTrainingRuntime` manifest that this job references.
- **GPU Operator running** — `nvidia.com/gpu` capacity available on the GPU node.
- `kubectl` configured to the target cluster context.

## Run

```bash
# Submit
make apply

# Watch until done (polls every 10 s)
make wait

# Stream logs
make logs

# Show final status
make status

# Clean up
make clean
```

Or directly with kubectl:

```bash
kubectl apply -f pytorch-mnist-gpu.yaml
kubectl get trainjob pytorch-mnist-gpu -n kubeflow -w
kubectl logs -l trainer.kubeflow.org/trainjob-name=pytorch-mnist-gpu -n kubeflow
```

## What it validates

| Check | Expected |
|---|---|
| TrainJob lifecycle | `JobComplete` |
| Trainer v2 runtime | `torch-distributed` ClusterTrainingRuntime resolves |
| Container exit code | `0` |
| Scheduled node | GPU node (`nvidia.com/gpu` taint tolerated) |
| GPU resource | `nvidia.com/gpu: 1` requested and allocated |
| CUDA available | `True` — NVIDIA driver + container toolkit working |
| Training throughput | ~200 steps in < 60 s on RTX 4000 Ada |

## Validation result (cluster lke609184, Kubeflow 26.03)

```text
PyTorch version : 2.3.0+cu121
CUDA available  : True
GPU device      : NVIDIA RTX 4000 Ada Generation
GPU memory      : 13795 MB
Training on     : cuda
  step  50/200  loss=2.3036
  step 100/200  loss=2.2980
  step 150/200  loss=2.2859
  step 200/200  loss=2.2647
Training complete: 200 steps in ~40s (>1000 samples/s on cuda)
VALIDATION PASSED
```

## Notes

- Uses the **Trainer v2 `TrainJob` API** (`trainer.kubeflow.org/v1alpha1`).
  The `ClusterTrainingRuntime` named `torch-distributed` is installed by
  `platform/install.sh` step 5.
- For pure GPU substrate validation (no Kubeflow required), see
  [`examples/gpu-validation/`](../gpu-validation/) in
  [`akamai-lke-gpu-cluster`](https://github.com/idvoretskyi/akamai-lke-gpu-cluster).

## Customisation

- **Steps / batch size**: edit `steps` and `batch_size` in the inline script.
- **Distributed training**: set `numNodes > 1` for multi-node data-parallel training.
- **Real dataset**: replace `torch.randn` tensors with a `torchvision.datasets.MNIST` loader.
