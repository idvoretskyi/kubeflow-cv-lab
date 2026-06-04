#!/usr/bin/env sh
# uninstall.sh — Remove the Kubeflow Platform installed by install.sh.
#
# This script deletes all Kubeflow namespaces and CRDs from the cluster. It
# does NOT touch the GPU operator or any other cluster infrastructure.
#
# Configuration:
#   KF_VERSION  — kubeflow/manifests version to clone for deletion manifests
#                 (default: 26.03). Can also be set in platform/config.env.
#
# Usage:
#   ./platform/uninstall.sh
#   KF_VERSION=26.03 ./platform/uninstall.sh

set -eu

# ---------------------------------------------------------------------------
# Source config.env if present.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${SCRIPT_DIR}/config.env" ]; then
  # shellcheck source=/dev/null
  . "${SCRIPT_DIR}/config.env"
fi

KF_VERSION="${KF_VERSION-26.03}"

# ---------------------------------------------------------------------------
# Preflight.
# ---------------------------------------------------------------------------
for bin in kubectl kustomize git; do
  if ! command -v "$bin" > /dev/null 2>&1; then
    echo "Error: '$bin' not found on PATH." >&2
    exit 1
  fi
done

if ! kubectl cluster-info > /dev/null 2>&1; then
  echo "Error: cannot reach the cluster. Check your KUBECONFIG / current context." >&2
  exit 1
fi

echo "Uninstalling Kubeflow ${KF_VERSION} …"
echo ""
echo "WARNING: This will delete all Kubeflow namespaces, CRDs, and resources."
printf "Continue? [y/N] "
read -r REPLY
case "$REPLY" in
  [yY][eE][sS]|[yY]) ;;
  *) echo "Aborted."; exit 0 ;;
esac

# ---------------------------------------------------------------------------
# Work directory + cleanup.
# ---------------------------------------------------------------------------
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT INT TERM

echo "Cloning kubeflow/manifests at ${KF_VERSION} …"
git clone --depth 1 --branch "${KF_VERSION}" \
  https://github.com/kubeflow/manifests.git "${WORKDIR}/manifests"

cd "${WORKDIR}/manifests"

# ---------------------------------------------------------------------------
# Delete in reverse order (resources before CRDs).
# ---------------------------------------------------------------------------
echo "Deleting Kubeflow resources …"
kustomize build example | kubectl delete --ignore-not-found=true -f - || true

# Remove ClusterTrainingRuntimes if they were applied.
RUNTIMES_OVERLAY="${WORKDIR}/manifests/applications/trainer/upstream/overlays/runtimes"
if [ -d "${RUNTIMES_OVERLAY}" ]; then
  echo "Deleting ClusterTrainingRuntimes …"
  kustomize build "${RUNTIMES_OVERLAY}" | kubectl delete --ignore-not-found=true -f - || true
fi

echo ""
echo "Done. Kubeflow ${KF_VERSION} has been removed."
echo ""
echo "Note: PersistentVolumeClaims (databases, pipelines artifacts) are not"
echo "deleted automatically. Remove them manually if disk space is a concern:"
echo "  kubectl get pvc -A | grep -v kube-system"
