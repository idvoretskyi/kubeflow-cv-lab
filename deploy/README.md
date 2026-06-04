# deploy/

Cluster manifests for the lab (kustomize). Added in **Phase 2**.

Planned contents:

- `namespace.yaml` — the `cv-lab` namespace.
- `cluster/` — the single additive `NetworkPolicy` allowing `cv-lab → seaweedfs:8333`
  in the `kubeflow` namespace (the only change made to upstream Kubeflow).
- `postgres/` — PostgreSQL backend store for MLflow (Deployment, Service, PVC,
  example Secret).
- `mlflow/` — MLflow tracking server (`--serve-artifacts`, artifacts on SeaweedFS
  S3 `s3://mlflow`, backend on Postgres).

Apply with `kubectl apply -k deploy/`.
