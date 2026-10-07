#!/bin/sh
# deploy/bootstrap.sh — one-shot, idempotent prerequisites for the lab layer.
#
#   1. Kubeflow Profile `cv-lab` (creates the namespace + RBAC)
#   2. Secret cv-lab/postgres-credentials   (random password, created once)
#   3. Secret cv-lab/seaweedfs-s3-credentials
#        copied by the *operator's* kubectl from the upstream Kubeflow Secret
#        kubeflow/mlpipeline-minio-artifact (keys accesskey/secretkey).
#        Pods never read Secrets across namespaces.
#
# Usage:
#   make bootstrap
#   KF_PROFILE_OWNER=me@example.com sh deploy/bootstrap.sh
#
# Environment:
#   KF_PROFILE_OWNER       Profile owner (default: user@example.com, the Dex demo user)
#   SEAWEEDFS_ACCESS_KEY   override instead of copying from the kubeflow namespace
#   SEAWEEDFS_SECRET_KEY   (both must be set to override)

set -eu

KF_PROFILE_OWNER="${KF_PROFILE_OWNER:-user@example.com}"
NAMESPACE=cv-lab   # fixed: deploy/, serving/ and the pipeline assume it
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
kubectl get crd profiles.kubeflow.org >/dev/null 2>&1 \
  || die "Profile CRD missing — run 'make platform-install' first"

b64d() { base64 -d 2>/dev/null || base64 -D; }

# --- 1. Profile -------------------------------------------------------------
log "Applying Profile ${NAMESPACE} (owner: ${KF_PROFILE_OWNER})"
sed "s|name: user@example.com|name: ${KF_PROFILE_OWNER}|" "${SCRIPT_DIR}/profile.yaml" | kubectl apply -f -

log "Waiting for namespace ${NAMESPACE}"
i=0
until kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -le 60 ] || die "namespace ${NAMESPACE} not created by the profile controller"
  sleep 2
done

# --- 2. Postgres credentials ---------------------------------------------------
if kubectl -n "${NAMESPACE}" get secret postgres-credentials >/dev/null 2>&1; then
  log "Secret postgres-credentials exists — keeping it"
else
  log "Creating Secret postgres-credentials (random password)"
  pw=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
  kubectl -n "${NAMESPACE}" create secret generic postgres-credentials \
    --from-literal=POSTGRES_USER=mlflow \
    --from-literal=POSTGRES_PASSWORD="${pw}" \
    --from-literal=POSTGRES_DB=mlflow
fi

# --- 3. SeaweedFS S3 credentials ---------------------------------------------
if [ -n "${SEAWEEDFS_ACCESS_KEY:-}" ] && [ -n "${SEAWEEDFS_SECRET_KEY:-}" ]; then
  log "Using SeaweedFS credentials from the environment"
  ak="${SEAWEEDFS_ACCESS_KEY}"
  sk="${SEAWEEDFS_SECRET_KEY}"
else
  log "Copying SeaweedFS S3 credentials from kubeflow/mlpipeline-minio-artifact"
  ak=$(kubectl -n kubeflow get secret mlpipeline-minio-artifact \
        -o jsonpath='{.data.accesskey}' | b64d) \
    || die "cannot read kubeflow/mlpipeline-minio-artifact (set SEAWEEDFS_ACCESS_KEY/SECRET_KEY)"
  sk=$(kubectl -n kubeflow get secret mlpipeline-minio-artifact \
        -o jsonpath='{.data.secretkey}' | b64d)
fi
if [ -z "${ak}" ] || [ -z "${sk}" ]; then
  die "empty SeaweedFS credentials"
fi

kubectl -n "${NAMESPACE}" create secret generic seaweedfs-s3-credentials \
  --from-literal=AWS_ACCESS_KEY_ID="${ak}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${sk}" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Bootstrap complete. Next: make deploy"
