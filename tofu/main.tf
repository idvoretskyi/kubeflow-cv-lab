# Optional, state-tracked alternative to `make deploy`.
#
# Applies the very same manifests as `kubectl apply -k deploy/` (read from
# deploy/base/ — no duplicated YAML). The only tofu-specific knob is the
# Postgres StorageClass. Run `make bootstrap` first (Profile + Secrets are kept
# out of tofu state on purpose).

locals {
  base = "${path.module}/../deploy/base"

  manifests = {
    networkpolicy_seaweedfs = yamldecode(file("${local.base}/cluster/networkpolicy-seaweedfs.yaml"))
    postgres_deployment     = yamldecode(file("${local.base}/postgres/deployment.yaml"))
    postgres_service        = yamldecode(file("${local.base}/postgres/service.yaml"))
    mlflow_deployment       = yamldecode(file("${local.base}/mlflow/deployment.yaml"))
    mlflow_service          = yamldecode(file("${local.base}/mlflow/service.yaml"))
  }

  pvc_base = yamldecode(file("${local.base}/postgres/pvc.yaml"))
  # null -> attribute omitted -> cluster default StorageClass.
  postgres_pvc = merge(local.pvc_base, {
    spec = merge(local.pvc_base.spec, {
      storageClassName = var.postgres_storage_class != "" ? var.postgres_storage_class : null
    })
  })
}

resource "kubernetes_manifest" "postgres_pvc" {
  manifest = local.postgres_pvc
}

resource "kubernetes_manifest" "lab" {
  for_each = local.manifests
  manifest = each.value

  depends_on = [kubernetes_manifest.postgres_pvc]
}

