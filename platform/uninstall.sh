#!/bin/sh
# uninstall.sh — Remove the Kubeflow Platform installed by install.sh.
#
# This script deletes all Kubeflow namespaces and CRDs from the cluster. It
# does NOT touch the GPU operator or any other cluster infrastructure.
#
# Deletion uses the upstream `example` kustomization, a superset of both
# KF_PROFILE=minimal and full, so it works for either install profile.
#
# Configuration (same sources as install.sh: PRESET, config.env, env vars):
#   KF_VERSION  — kubeflow/manifests tag to clone (default: 26.03.1)
#   KF_YES=1    — skip the confirmation prompt (or pass --yes)
#   KF_REMOVE_LAB=1 — acknowledge that the cv-lab layer (Profile, namespace,
#                     MLflow, Postgres + PVC, InferenceService) is deleted too,
#                     and remove its SeaweedFS NetworkPolicy (or pass --with-lab).
#                     Required when cv-lab exists: removing the Profiles/KServe
#                     CRDs destroys it anyway, so the script refuses otherwise.
#
# Usage:
#   ./platform/uninstall.sh
#   ./platform/uninstall.sh --yes

set -eu

# ---------------------------------------------------------------------------
# Source preset then config.env; an explicitly supplied KF_VERSION wins.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for arg in "$@"; do
  case "$arg" in
    --yes|-y) KF_YES=1 ;;
    --with-lab) KF_REMOVE_LAB=1 ;;
    *) echo "Error: unknown argument '$arg' (use --yes, --with-lab)." >&2; exit 1 ;;
  esac
done
CLI_KF_VERSION_SET=${KF_VERSION+x}
CLI_KF_VERSION=${KF_VERSION-}
if [ -n "${PRESET:-}" ]; then
  PRESET_FILE="${SCRIPT_DIR}/presets/${PRESET}.env"
  if [ ! -f "${PRESET_FILE}" ]; then
    echo "Error: preset file '${PRESET_FILE}' not found." >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  . "${PRESET_FILE}"
fi
if [ -f "${SCRIPT_DIR}/config.env" ]; then
  # shellcheck source=/dev/null
  . "${SCRIPT_DIR}/config.env"
fi
if [ -n "${CLI_KF_VERSION_SET}" ]; then KF_VERSION=${CLI_KF_VERSION}; fi

KF_VERSION="${KF_VERSION-26.03.1}"

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

if [ "${KF_REMOVE_LAB:-}" != "1" ] && {
  kubectl get namespace cv-lab > /dev/null 2>&1 ||
    kubectl get profile cv-lab > /dev/null 2>&1
}; then
  echo "Error: the cv-lab layer exists and uninstalling Kubeflow would delete it" >&2
  echo "  (Profile -> namespace -> Postgres PVC, and the KServe InferenceService)." >&2
  echo "  Back up first if you need the data, e.g.:" >&2
  echo "    kubectl -n cv-lab exec deploy/postgres -- sh -c 'pg_dump -U \"\$POSTGRES_USER\" \"\$POSTGRES_DB\"' > mlflow.sql" >&2
  echo "  then re-run with --with-lab (or KF_REMOVE_LAB=1) to confirm." >&2
  exit 1
fi

echo "Uninstalling Kubeflow ${KF_VERSION} …"
echo ""
echo "WARNING: This will delete all Kubeflow namespaces, CRDs, and resources."
if [ "${KF_YES:-}" = "1" ]; then
  REPLY=y
else
  printf "Continue? [y/N] "
  read -r REPLY
fi
case "$REPLY" in
  [yY][eE][sS]|[yY]) ;;
  *) echo "Aborted."; exit 0 ;;
esac

# ---------------------------------------------------------------------------
# Work directory + cleanup.
# ---------------------------------------------------------------------------
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Cloning kubeflow/manifests at ${KF_VERSION} …"
git clone --depth 1 --branch "${KF_VERSION}" \
  https://github.com/kubeflow/manifests.git "${WORKDIR}/manifests"

cd "${WORKDIR}/manifests"

# ---------------------------------------------------------------------------
# Delete in reverse order (resources before CRDs).
# ---------------------------------------------------------------------------
if [ "${KF_REMOVE_LAB:-}" = "1" ]; then
  echo "Deleting the cv-lab layer (Profile, namespace, data, SeaweedFS NetworkPolicy) …"
  kubectl delete profile cv-lab --ignore-not-found=true --wait=true || \
    echo "Warning: could not delete the cv-lab Profile." >&2
  kubectl -n kubeflow delete networkpolicy allow-cv-lab-to-seaweedfs --ignore-not-found=true || true
fi

# Two passes: custom resources may only be deletable once the first pass has
# processed their finalizers.
echo "Deleting Kubeflow resources …"
kustomize build example > "${WORKDIR}/example.yaml"
for pass in 1 2; do
  kubectl delete --ignore-not-found=true -f "${WORKDIR}/example.yaml" || \
    echo "Warning: some resources could not be deleted on pass ${pass}." >&2
done

# Remove ClusterTrainingRuntimes if they were applied.
RUNTIMES_OVERLAY="${WORKDIR}/manifests/applications/trainer/upstream/overlays/runtimes"
if [ -d "${RUNTIMES_OVERLAY}" ]; then
  echo "Deleting ClusterTrainingRuntimes …"
  kustomize build "${RUNTIMES_OVERLAY}" | kubectl delete --ignore-not-found=true -f - || \
    echo "Warning: ClusterTrainingRuntimes could not be fully deleted." >&2
fi

echo ""
echo "Done. Kubeflow ${KF_VERSION} has been removed."
echo ""
echo "Note: PersistentVolumeClaims (databases, pipelines artifacts) are not"
echo "deleted automatically. Remove them manually if disk space is a concern:"
echo "  kubectl get pvc -A | grep -v kube-system"
