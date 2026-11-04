terraform {
  required_version = ">= 1.10"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }

  # Remote state: Linode Object Storage (S3-compatible).
  # Configure with: tofu init -backend-config=backend.conf
  # Copy backend.conf.example → backend.conf and fill in your keys.
  backend "s3" {}
}
