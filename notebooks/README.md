# notebooks/

`explore.ipynb` sends a test image to the KServe predictor and draws the
detections with [`supervision`](https://supervision.roboflow.com/).

The minimal Kubeflow profile does not install Kubeflow Notebooks, so run the
notebook on your workstation:

```bash
make port-forward-predictor        # terminal 1
pip install jupyterlab             # terminal 2
jupyter lab notebooks/explore.ipynb
```

With `KF_PROFILE=full` you can also run it from a Kubeflow Notebook in the
`cv-lab` namespace. In that case set
`INFER_URL=http://yolov8-coco128-predictor.cv-lab/v1/models/yolov8-coco128:predict`.
