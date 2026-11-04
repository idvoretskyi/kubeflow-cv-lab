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

The scheduling contract is shared with the training pipeline and lives in
``pipeline/gpu_scheduling.py`` (see it for the compile-time env overrides,
e.g. GPU_NODE_SELECTOR_KEY="" to drop the node selector).

Compile:
    python gpu_pipeline.py              # writes gpu_pipeline.yaml
Or:
    kfp dsl compile --py gpu_pipeline.py --output gpu_pipeline.yaml
"""

import pathlib
import sys

from kfp import compiler, dsl

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "pipeline"))
from gpu_scheduling import gpu_task  # noqa: E402
from versions import CUDA_BASE_IMAGE  # noqa: E402


@dsl.container_component
def nvidia_smi():
    """Run nvidia-smi in a CUDA base image to confirm GPU visibility."""
    return dsl.ContainerSpec(
        image=CUDA_BASE_IMAGE,
        command=["nvidia-smi"],
    )


@dsl.pipeline(
    name="gpu-smoke-test",
    description="Runs nvidia-smi on a GPU node to validate GPU scheduling.",
)
def gpu_pipeline():
    gpu_task(nvidia_smi())


if __name__ == "__main__":
    compiler.Compiler().compile(
        pipeline_func=gpu_pipeline,
        package_path=str(pathlib.Path(__file__).with_suffix(".yaml")),
    )
