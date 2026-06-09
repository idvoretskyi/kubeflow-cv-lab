# ----------------------------------------------------------------------------
# Prerequisites — applied separately (not managed by this Tofu module)
# ----------------------------------------------------------------------------
# 1. Secrets — created outside Tofu to avoid storing credentials in state:
#      kubectl apply -f deploy/postgres/secret.yaml     (from secret.example.yaml)
#      kubectl apply -f secrets/seaweedfs-s3-credentials.yaml
#      kubectl apply -f secrets/roboflow-api-key.yaml
#
# 2. Kubeflow Profile CR — creates cv-lab namespace + RBAC:
#      kubectl apply -f deploy/profile.yaml
#    The Profile CRD is installed by platform/install.sh; run this after Kubeflow
#    is up. The cv-lab namespace must exist before resources below can be planned.
#
# 3. SeaweedFS mlflow bucket — one-shot Job (run once):
#      kubectl apply -f deploy/mlflow/create-bucket-job.yaml
# ----------------------------------------------------------------------------

# Allow cv-lab namespace pods to reach SeaweedFS S3 (port 8333) in kubeflow ns.
resource "kubernetes_manifest" "networkpolicy_seaweedfs" {
  manifest = yamldecode(file("${path.module}/../deploy/cluster/networkpolicy-seaweedfs.yaml"))
}

# ----------------------------------------------------------------------------
# Postgres (MLflow backend store)
# ----------------------------------------------------------------------------

# PVC — storageClass is the only cluster-specific parameter; all others are
# cloud-neutral and match deploy/postgres/pvc.yaml.
resource "kubernetes_manifest" "postgres_pvc" {
  manifest = {
    apiVersion = "v1"
    kind       = "PersistentVolumeClaim"
    metadata = {
      name      = "postgres-pvc"
      namespace = var.namespace
    }
    spec = {
      # null → omit storageClassName → use cluster default StorageClass.
      storageClassName = var.postgres_storage_class != "" ? var.postgres_storage_class : null
      accessModes      = ["ReadWriteOnce"]
      resources = {
        requests = {
          storage = "10Gi"
        }
      }
    }
  }
}

resource "kubernetes_manifest" "postgres_deployment" {
  manifest   = yamldecode(file("${path.module}/../deploy/postgres/deployment.yaml"))
  depends_on = [kubernetes_manifest.postgres_pvc]
}

resource "kubernetes_manifest" "postgres_service" {
  manifest = yamldecode(file("${path.module}/../deploy/postgres/service.yaml"))
}

# ----------------------------------------------------------------------------
# MLflow (tracking server + proxied artifact server)
# ----------------------------------------------------------------------------

resource "kubernetes_manifest" "mlflow_deployment" {
  manifest   = yamldecode(file("${path.module}/../deploy/mlflow/deployment.yaml"))
  depends_on = [kubernetes_manifest.postgres_deployment]
}

resource "kubernetes_manifest" "mlflow_service" {
  manifest = yamldecode(file("${path.module}/../deploy/mlflow/service.yaml"))
}
