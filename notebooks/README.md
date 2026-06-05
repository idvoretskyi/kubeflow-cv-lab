# notebooks/

Visualization notebook for **Phase 5**.

## Contents

- `explore.ipynb` — sends a test image to the KServe `InferenceService` and
  draws the predicted bounding boxes with
  [`supervision`](https://supervision.roboflow.com/).

## How to run

1. Open the `cv-lab-notebook` JupyterLab instance from the Kubeflow Central
   Dashboard (profile: `cv-lab`).
2. Upload or open `explore.ipynb`.
3. Run all cells (`Run → Run All Cells`).

The notebook pod is in the `cv-lab` namespace so it can reach the predictor
service at `http://yolov8-coco128-predictor.cv-lab` without additional network
configuration.
