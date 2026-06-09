# deploy/

Cluster manifests for the `cv-lab` lab namespace (kustomize).

## Structure

```text
deploy/
├── profile.yaml                        # Kubeflow Profile CR → creates cv-lab namespace
├── cluster/
│   └── networkpolicy-seaweedfs.yaml    # Only change to the kubeflow namespace: allow cv-lab → seaweedfs:8333
├── postgres/
│   ├── pvc.yaml                        # 10 Gi PVC (cloud-neutral; set storageClass via Tofu or kustomize patch)
│   ├── deployment.yaml                 # postgres:16-alpine
│   ├── service.yaml
│   └── secret.example.yaml            # Copy to secret.yaml and fill in passwords
├── mlflow/
│   ├── deployment.yaml                 # ghcr.io/mlflow/mlflow, --serve-artifacts, s3://mlflow backend
│   ├── service.yaml
│   └── create-bucket-job.yaml         # One-shot Job: creates the mlflow S3 bucket
└── kustomization.yaml
```

## Option A — Tofu-managed (recommended)

```bash
cd tofu
cp backend.conf.example backend.conf   # fill in Linode OBJ keys
cp tofu.tfvars.example tofu.tfvars     # set postgres_storage_class for your cluster
tofu init -backend-config=backend.conf
tofu apply -var-file=tofu.tfvars
```

Secrets and the Profile CR are applied separately (see Option B steps 1–2).

## Option B — kubectl / kustomize

```bash
# 1. Create the Profile (namespace + RBAC)
kubectl apply -f deploy/profile.yaml

# 2. Apply real secrets (not committed — copy from examples)
cp secrets/seaweedfs-s3-credentials.example.yaml secrets/seaweedfs-s3-credentials.yaml
cp deploy/postgres/secret.example.yaml deploy/postgres/secret.yaml
# edit both files with real values, then:
kubectl apply -f secrets/seaweedfs-s3-credentials.yaml
kubectl apply -f secrets/roboflow-api-key.yaml   # your real key
kubectl apply -f deploy/postgres/secret.yaml

# 3. Apply remaining manifests
kubectl apply -k deploy/

# 4. Create the mlflow S3 bucket (once)
kubectl apply -f deploy/mlflow/create-bucket-job.yaml
kubectl wait --for=condition=complete job/mlflow-create-bucket -n cv-lab --timeout=120s

# 5. Verify
kubectl rollout status deployment/postgres -n cv-lab
kubectl rollout status deployment/mlflow -n cv-lab
kubectl port-forward svc/mlflow 5000:5000 -n cv-lab
# open http://localhost:5000
```

## Notes

- Postgres and MLflow pods have `sidecar.istio.io/inject: "false"` — they sit
  outside the Istio mesh so mTLS complexity is avoided.
- The `seaweedfs-s3-credentials` Secret is namespace-scoped to `cv-lab`; it is
  never read cross-namespace.
- `deploy/postgres/secret.yaml` and `secrets/*.yaml` are git-ignored.
- `deploy/postgres/pvc.yaml` omits `storageClassName` so it works on any cluster.
  Set `postgres_storage_class = "linode-block-storage-retain"` in `tofu/tofu.tfvars`
  for Akamai LKE to ensure volume persistence across node replacements.
