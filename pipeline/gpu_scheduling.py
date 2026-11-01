"""Shared GPU scheduling contract for every KFP pipeline in this repo.

Used by ``pipeline/pipeline.py`` and ``examples/kubeflow-pipelines/gpu_pipeline.py``
so the contract documented in AGENTS.md lives in exactly one place.

Contract
--------
GPU steps (``gpu_task``):
  * request one GPU      -> set_accelerator_type("nvidia.com/gpu") + limit 1  (hard guarantee)
  * tolerate GPU taint   -> nvidia.com/gpu:NoSchedule (no-op on untainted nodes)
  * select GPU nodes     -> GPU Feature Discovery label nvidia.com/gpu.present=true

CPU steps (``cpu_task``):
  * tolerate the GPU taint only, so on the reference 2-node cluster (one small
    system node + one GPU node) CPU steps may overflow onto the GPU node's spare
    CPU/RAM without consuming a GPU. Disable with GPU_TOLERATE_CPU_STEPS=0.

Compile-time environment overrides (no cloud-specific literals are committed):
  GPU_NODE_SELECTOR_KEY    default nvidia.com/gpu.present  ("" disables the selector)
  GPU_NODE_SELECTOR_VALUE  default true
  GPU_TAINT_KEY            default nvidia.com/gpu
  GPU_TAINT_EFFECT         default NoSchedule
  GPU_TOLERATE_CPU_STEPS   default 1
"""

from __future__ import annotations

import os

from kfp import dsl, kubernetes

GPU_RESOURCE = "nvidia.com/gpu"
GPU_NODE_SELECTOR_KEY = os.environ.get("GPU_NODE_SELECTOR_KEY", "nvidia.com/gpu.present")
GPU_NODE_SELECTOR_VALUE = os.environ.get("GPU_NODE_SELECTOR_VALUE", "true")
GPU_TAINT_KEY = os.environ.get("GPU_TAINT_KEY", "nvidia.com/gpu")
GPU_TAINT_EFFECT = os.environ.get("GPU_TAINT_EFFECT", "NoSchedule")
GPU_TOLERATE_CPU_STEPS = os.environ.get("GPU_TOLERATE_CPU_STEPS", "1") not in ("0", "false", "")


def _tolerate_gpu_taint(task: dsl.PipelineTask) -> None:
    if GPU_TAINT_KEY:
        kubernetes.add_toleration(
            task, key=GPU_TAINT_KEY, operator="Exists", effect=GPU_TAINT_EFFECT
        )


def gpu_task(task: dsl.PipelineTask) -> dsl.PipelineTask:
    """Pin ``task`` to a GPU node and request exactly one GPU."""
    task.set_accelerator_type(GPU_RESOURCE)
    task.set_accelerator_limit(1)
    _tolerate_gpu_taint(task)
    if GPU_NODE_SELECTOR_KEY:
        kubernetes.add_node_selector(
            task, label_key=GPU_NODE_SELECTOR_KEY, label_value=GPU_NODE_SELECTOR_VALUE
        )
    return task


def cpu_task(task: dsl.PipelineTask) -> dsl.PipelineTask:
    """Allow a CPU-only ``task`` to overflow onto GPU nodes (without a GPU)."""
    if GPU_TOLERATE_CPU_STEPS:
        _tolerate_gpu_taint(task)
    return task
