# serving/

KServe serving manifests. Added in **Phase 4**.

Planned contents:

- `s3-serviceaccount.yaml` — `ServiceAccount` + S3 `Secret` annotated for KServe
  (endpoint `seaweedfs.kubeflow:8333`, path-style, using the lab's own
  `seaweedfs-s3-credentials` Secret).
- `inferenceservice.yaml` — custom predictor loading the registered YOLO model
  from `s3://mlflow/.../weights`.

Apply with `kubectl apply -f serving/` once a model has been registered.
