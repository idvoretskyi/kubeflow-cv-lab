"""GPU smoke-test pipeline for Kubeflow Pipelines (KFP v2).

Demonstrates running a pipeline step on a GPU node. Because GPU nodes are
commonly tainted (e.g. nvidia.com/gpu=present:NoSchedule) so they stay
reserved for GPU work, a GPU step must explicitly:

  1. request a GPU                    -> set_accelerator_type / _limit
  2. tolerate the GPU node taint      -> kubernetes.add_toleration
  3. identify the target GPU nodes    -> kubernetes.add_node_selector
                                         (uses the GPU Feature Discovery label
                                          nvidia.com/gpu.present=true, which is
                                          set automatically by the NVIDIA GPU
                                          Operator on every GPU node regardless
                                          of cloud provider)

GPU node identification uses the GPU Feature Discovery (GFD) label:
  nvidia.com/gpu.present=true
This label is written by the GPU Operator's GFD component and is present on
every GPU node on any cluster running the operator — no cloud-specific pool
label is required. The GPU resource request alone is the hard scheduling
guarantee; the node selector makes the intent explicit and filters to
GFD-labelled nodes.

Node selector and taint key are configurable via environment variables so
they can be overridden for specific clusters without changing the source:
  GPU_NODE_SELECTOR_KEY   (default: nvidia.com/gpu.present)
  GPU_NODE_SELECTOR_VALUE (default: true)
  GPU_TAINT_KEY           (default: nvidia.com/gpu)
  GPU_TAINT_EFFECT        (default: NoSchedule)

Set GPU_NODE_SELECTOR_KEY="" to disable the node selector entirely.

Compile:
    python gpu_pipeline.py              # writes gpu_pipeline.yaml
Or:
    kfp dsl compile --py gpu_pipeline.py --output gpu_pipeline.yaml
"""

import os

from kfp import dsl
from kfp import kubernetes

# GPU node identification — GPU Feature Discovery (GFD) label.
# Written by the NVIDIA GPU Operator on every GPU node; vendor-neutral.
# Override via env for clusters using a different node labelling scheme.
GPU_NODE_SELECTOR_KEY = os.environ.get("GPU_NODE_SELECTOR_KEY", "nvidia.com/gpu.present")
GPU_NODE_SELECTOR_VALUE = os.environ.get("GPU_NODE_SELECTOR_VALUE", "true")

# Taint configuration — matches the NVIDIA device plugin / GPU Operator default.
# Override via env if your cluster uses a different taint key.
GPU_TAINT_KEY = os.environ.get("GPU_TAINT_KEY", "nvidia.com/gpu")
GPU_TAINT_EFFECT = os.environ.get("GPU_TAINT_EFFECT", "NoSchedule")


@dsl.container_component
def nvidia_smi():
    """Run nvidia-smi in a CUDA base image to confirm GPU visibility."""
    return dsl.ContainerSpec(
        image="nvidia/cuda:12.4.1-base-ubuntu22.04",
        command=["nvidia-smi"],
    )


@dsl.pipeline(
    name="gpu-smoke-test",
    description="Runs nvidia-smi on a GPU node to validate GPU scheduling.",
)
def gpu_pipeline():
    task = nvidia_smi()

    # 1. Request one GPU (hard scheduling guarantee — pod only lands on a node
    #    advertising nvidia.com/gpu capacity).
    task.set_accelerator_type("nvidia.com/gpu")
    task.set_accelerator_limit(1)

    # 2. Tolerate the GPU node taint so the step can land on a tainted GPU node.
    #    This is a no-op on clusters where GPU nodes are not tainted.
    kubernetes.add_toleration(
        task,
        key=GPU_TAINT_KEY,
        operator="Exists",
        effect=GPU_TAINT_EFFECT,
    )

    # 3. Target GPU nodes identified by the GPU Feature Discovery label.
    #    nvidia.com/gpu.present=true is set by the NVIDIA GPU Operator's GFD
    #    component on every GPU node, regardless of cloud provider.
    #    Set GPU_NODE_SELECTOR_KEY="" to skip this selector.
    if GPU_NODE_SELECTOR_KEY:
        kubernetes.add_node_selector(
            task,
            label_key=GPU_NODE_SELECTOR_KEY,
            label_value=GPU_NODE_SELECTOR_VALUE,
        )


if __name__ == "__main__":
    from kfp import compiler

    compiler.Compiler().compile(
        pipeline_func=gpu_pipeline,
        package_path="gpu_pipeline.yaml",
    )
