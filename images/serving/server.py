"""KServe custom predictor for YOLOv8 object detection.

Loads a YOLOv8 model from the MLflow Model Registry at startup,
then serves inference requests over the KServe V1 prediction protocol.

Environment variables
---------------------
MODEL_NAME            KServe model name            (default: yolov8-coco128)
MODEL_URI             MLflow model URI             (default: models:/yolov8-coco128/1)
MLFLOW_TRACKING_URI   MLflow server URL            (default: http://mlflow.cv-lab:5000)

Request format
--------------
POST /v1/models/{MODEL_NAME}:predict
{
    "instances": [
        {"image": {"b64": "<base64-encoded PNG/JPEG>"}}
    ]
}

Response format
---------------
{
    "predictions": [
        {
            "boxes":       [[x1, y1, x2, y2], ...],
            "scores":      [confidence, ...],
            "class_ids":   [int, ...],
            "class_names": ["person", ...]
        }
    ]
}
"""

import base64
import glob
import io
import os
import tempfile

import kserve
import mlflow
from PIL import Image


class YOLOv8Model(kserve.Model):
    """KServe Model wrapping Ultralytics YOLOv8."""

    def __init__(self, name: str) -> None:
        super().__init__(name)
        self.mlflow_tracking_uri = os.environ.get(
            "MLFLOW_TRACKING_URI", "http://mlflow.cv-lab:5000"
        )
        self.model_uri = os.environ.get("MODEL_URI", "models:/yolov8-coco128/1")
        self._model_dir = tempfile.mkdtemp(prefix="yolo_weights_")
        self.yolo = None
        self.ready = False

    def load(self) -> bool:
        """Download model from MLflow and initialise YOLOv8."""
        from ultralytics import YOLO  # deferred: large import, avoid at module level

        mlflow.set_tracking_uri(self.mlflow_tracking_uri)
        print(f"Downloading model from {self.model_uri} ...")
        local_path = mlflow.artifacts.download_artifacts(
            artifact_uri=self.model_uri,
            dst_path=self._model_dir,
        )
        pts = sorted(
            glob.glob(os.path.join(local_path, "**", "best.pt"), recursive=True)
        )
        if not pts:
            pts = sorted(
                glob.glob(os.path.join(local_path, "**", "*.pt"), recursive=True)
            )
        if not pts:
            raise FileNotFoundError(f"No .pt weights file found under {local_path}")

        print(f"Loading weights: {pts[0]}")
        self.yolo = YOLO(pts[0])
        self.ready = True
        print("Model ready.")
        return self.ready

    @staticmethod
    def _to_list(tensor) -> list:
        return tensor.cpu().numpy().tolist()

    def predict(self, payload: dict, headers: dict | None = None) -> dict:
        """Run YOLOv8 inference on a batch of base64-encoded images."""
        instances = payload.get("instances", [])
        predictions = []
        for instance in instances:
            b64 = instance.get("image", {}).get("b64", "")
            img = Image.open(io.BytesIO(base64.b64decode(b64))).convert("RGB")
            result = self.yolo(img, verbose=False)[0]
            boxes = result.boxes
            cls_list = self._to_list(boxes.cls)
            predictions.append(
                {
                    "boxes": self._to_list(boxes.xyxy),
                    "scores": self._to_list(boxes.conf),
                    "class_ids": [int(c) for c in cls_list],
                    "class_names": [result.names[int(c)] for c in cls_list],
                }
            )
        return {"predictions": predictions}


if __name__ == "__main__":
    model_name = os.environ.get("MODEL_NAME", "yolov8-coco128")
    model = YOLOv8Model(name=model_name)
    kserve.ModelServer().start([model])
