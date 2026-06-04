# secrets/

Secret **templates** only. Never commit real credentials.

Real secret files match `secrets/*.yaml` and are git-ignored; only
`*.example.yaml` templates are tracked (see `.gitignore`).

## Templates

### `seaweedfs-s3-credentials.example.yaml`

S3 credentials for the lab's MLflow server and KServe serving pods. Both run in
the `cv-lab` namespace and read this Secret directly — Kubernetes Secrets are
namespace-scoped, so the lab keeps its own copy rather than reading across
namespaces.

Populate `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` with the S3 credentials
configured on your cluster's SeaweedFS instance.

### `roboflow-api-key.example.yaml`

Your Roboflow API key, consumed by the pipeline's `load_data` step to pull a
dataset from Roboflow Universe.

## Usage

```bash
# S3 credentials
cp secrets/seaweedfs-s3-credentials.example.yaml secrets/seaweedfs-s3-credentials.yaml
# edit AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY, then:
kubectl apply -f secrets/seaweedfs-s3-credentials.yaml

# Roboflow API key
cp secrets/roboflow-api-key.example.yaml secrets/roboflow-api-key.yaml
# edit the value, then:
kubectl apply -f secrets/roboflow-api-key.yaml
```
