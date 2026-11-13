variable "kubeconfig_path" {
  description = "Path to the kubeconfig file used to authenticate to the Kubernetes cluster."
  type        = string
  default     = "~/.kube/config"
}

variable "kubernetes_context" {
  description = "Kubernetes context to use. Empty string = current context in kubeconfig."
  type        = string
  default     = ""
}

variable "postgres_storage_class" {
  description = <<-EOT
    StorageClass name for the Postgres PVC.
      - a retaining class (e.g. "linode-block-storage-retain" on Akamai LKE; see
        deploy/overlays/lke) — persists the volume across node replacements.
      - "" (empty string, default) — omit storageClassName; Kubernetes will use the
        cluster default StorageClass.
    List available classes with: kubectl get storageclass
  EOT
  type        = string
  default     = ""
}
