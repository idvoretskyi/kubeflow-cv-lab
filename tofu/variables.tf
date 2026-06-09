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

variable "namespace" {
  description = "Kubernetes namespace for cv-lab resources (MLflow, Postgres)."
  type        = string
  default     = "cv-lab"
}

variable "postgres_storage_class" {
  description = <<-EOT
    StorageClass name for the Postgres PVC.
      - "linode-block-storage-retain" — persists the volume across node replacements
        on Akamai LKE (recommended for the lab's default deployment).
      - "" (empty string, default) — omit storageClassName; Kubernetes will use the
        cluster default StorageClass.
    List available classes with: kubectl get storageclass
  EOT
  type        = string
  default     = ""
}
