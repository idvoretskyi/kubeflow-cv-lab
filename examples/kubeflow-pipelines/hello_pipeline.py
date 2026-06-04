"""Minimal Kubeflow Pipelines (KFP v2) demo — CPU only.

A two-step "hello world" pipeline that verifies Pipelines is working end to end.
Both steps run as ordinary pods; because they carry no toleration for the GPU
node taint (nvidia.com/gpu=present:NoSchedule), the scheduler keeps them on the
system pool, leaving the GPU nodes free for GPU work.

Compile:
    python hello_pipeline.py            # writes hello_pipeline.yaml
Or:
    kfp dsl compile --py hello_pipeline.py --output hello_pipeline.yaml
"""

from kfp import dsl


@dsl.component(base_image="python:3.11-slim")
def say_hello(name: str) -> str:
    greeting = f"Hello, {name}!"
    print(greeting)
    return greeting


@dsl.component(base_image="python:3.11-slim")
def shout(text: str) -> str:
    loud = text.upper()
    print(loud)
    return loud


@dsl.pipeline(
    name="hello-world",
    description="Minimal CPU-only KFP v2 demo pipeline.",
)
def hello_pipeline(name: str = "Kubeflow") -> str:
    hello_task = say_hello(name=name)
    shout_task = shout(text=hello_task.output)
    return shout_task.output


if __name__ == "__main__":
    from kfp import compiler

    compiler.Compiler().compile(
        pipeline_func=hello_pipeline,
        package_path="hello_pipeline.yaml",
    )
