# secrets/

Secret **templates** only. Never commit credentials: real files match
`secrets/*.yaml` and are git-ignored; only `*.example.yaml` is tracked.

`make bootstrap` (`deploy/bootstrap.sh`) creates every Secret the lab needs, so
these templates are only for manual or GitOps setups.

| Template | Secret (in `cv-lab`) | Consumed by |
|---|---|---|
| `seaweedfs-s3-credentials.example.yaml` | `seaweedfs-s3-credentials` | MLflow (artifact proxy to SeaweedFS) |
| `../deploy/base/postgres/secret.example.yaml` | `postgres-credentials` | Postgres, MLflow |

Kubernetes Secrets are namespace-scoped, so the lab keeps its own copy of the
SeaweedFS keys rather than having pods read the `kubeflow` namespace. Training
and serving pods talk to MLflow over HTTP and need no S3 credentials.
