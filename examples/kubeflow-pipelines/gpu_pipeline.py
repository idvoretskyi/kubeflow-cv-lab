"""GPU smoke-test pipeline for Kubeflow Pipelines (KFP v2).

Demonstrates running a pipeline step on the *dedicated GPU pool*. Because the
GPU nodes are tainted (nvidia.com/gpu=present:NoSchedule) so they stay reserved
for GPU work, a GPU step must explicitly:

  1. request a GPU                       -> set_accelerator_type / _limit
  2. tolerate the GPU node taint         -> kubernetes.add_toleration
  3. (optionally) target the GPU pool    -> kubernetes.add_node_selector

The step runs `nvidia-smi` in a CUDA image and prints the visible GPU, which
confirms the GPU Operator, the taint/toleration wiring, and scheduling onto the
GPU pool all work together.

Compile:
    python gpu_pipeline.py              # writes gpu_pipeline.yaml
Or:
    kfp dsl compile --py gpu_pipeline.py --output gpu_pipeline.yaml
"""

from kfp import dsl
from kfp import kubernetes

# Must match tofu/locals.tf (gpu_node_taint) and the GPU pool label.
GPU_TAINT_KEY = "nvidia.com/gpu"
GPU_TAINT_EFFECT = "NoSchedule"
GPU_POOL_LABEL_KEY = "nodepool.lke/role"
GPU_POOL_LABEL_VALUE = "gpu"


@dsl.container_component
def nvidia_smi():
    """Run nvidia-smi in a CUDA base image to confirm GPU visibility."""
    return dsl.ContainerSpec(
        image="nvidia/cuda:12.4.1-base-ubuntu22.04",
        command=["nvidia-smi"],
    )


@dsl.pipeline(
    name="gpu-smoke-test",
    description="Runs nvidia-smi on the dedicated GPU pool to validate GPU scheduling.",
)
def gpu_pipeline():
    task = nvidia_smi()

    # 1. Request one GPU.
    task.set_accelerator_type("nvidia.com/gpu")
    task.set_accelerator_limit(1)

    # 2. Tolerate the GPU node taint so the step can land on a GPU node.
    kubernetes.add_toleration(
        task,
        key=GPU_TAINT_KEY,
        operator="Exists",
        effect=GPU_TAINT_EFFECT,
    )

    # 3. Pin to the GPU pool (optional; the GPU request already forces a GPU node).
    kubernetes.add_node_selector(
        task,
        label_key=GPU_POOL_LABEL_KEY,
        label_value=GPU_POOL_LABEL_VALUE,
    )


if __name__ == "__main__":
    from kfp import compiler

    compiler.Compiler().compile(
        pipeline_func=gpu_pipeline,
        package_path="gpu_pipeline.yaml",
    )
