# deploy/

The lab layer (`cv-lab` namespace): PostgreSQL + MLflow with proxied artifacts
stored in Kubeflow's SeaweedFS.

```bash
make bootstrap            # once: Profile + Secrets (deploy/bootstrap.sh, idempotent)
make deploy               # kubectl apply -k deploy/ and wait for rollouts
make deploy OVERLAY=lke   # same, with linode-block-storage-retain for Postgres
```

## Layout

| Path | Purpose |
|---|---|
| `bootstrap.sh` | Applies `profile.yaml` (owner `$KF_PROFILE_OWNER`, default `user@example.com`). Creates `postgres-credentials` with a random password once. Copies the SeaweedFS keys from `kubeflow/mlpipeline-minio-artifact` into `seaweedfs-s3-credentials`. |
| `profile.yaml` | Kubeflow `Profile` that creates the `cv-lab` namespace |
| `base/cluster/networkpolicy-seaweedfs.yaml` | The only addition to the `kubeflow` namespace: allows `cv-lab` → SeaweedFS `:8333` |
| `base/postgres/` | PostgreSQL 18 Deployment, Service, and 10 Gi PVC (default StorageClass) |
| `base/mlflow/` | MLflow 3.17 server (`--serve-artifacts --artifacts-destination s3://mlflow`) |
| `overlays/lke/` | Linode LKE: retained block storage for Postgres |

MLflow's `setup` init container is idempotent. It installs the Postgres and S3
drivers into a shared `emptyDir` (no custom image), creates the `mlflow` bucket
if it is missing, and runs `mlflow db upgrade`.

## Sizing

| Pod | Requests | Limit |
|---|---|---|
| postgres | 100m / 256 Mi | 512 Mi |
| mlflow | 200m / 512 Mi | 1.5 Gi |

Both tolerate the GPU taint so they can use spare capacity on the GPU node of
the two-node reference cluster. Neither requests a GPU.

## Verify

```bash
kubectl -n cv-lab get pods
make port-forward-mlflow   # http://localhost:5000
```
