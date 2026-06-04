# secrets/

Secret **templates** only. Never commit real credentials.

Real secret files match `secrets/*.yaml` and are git-ignored; only
`*.example.yaml` templates are tracked (see `.gitignore`).

Planned templates:

- `roboflow-api-key.example.yaml` — your Roboflow API key, consumed by the
  pipeline's `load_data` step.

The SeaweedFS S3 credentials are **not** stored here — they are read from the
cluster's existing `mlpipeline-minio-artifact` Secret in the `kubeflow` namespace.

Usage:

```bash
cp secrets/roboflow-api-key.example.yaml secrets/roboflow-api-key.yaml
# edit the value, then:
kubectl apply -f secrets/roboflow-api-key.yaml
```
