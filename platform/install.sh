#!/usr/bin/env sh
# install.sh — Install the full Kubeflow Platform from the upstream kustomize
# manifests onto any GPU-enabled Kubernetes cluster.
#
# Derived from akamai-lke-gpu-cluster/tofu/modules/kubeflow/scripts/install-kubeflow.sh
# (MIT licence, Ihor Dvoretskyi <ihor@linux.com>). Vendor-neutral rewrite:
#   - Uses the active kubeconfig context (no base64-encoded kubeconfig input).
#   - All cloud-specific values are parameterised via environment variables or
#     sourced from config.env in the same directory.
#   - Linode/Akamai LKE CIDRs are the built-in defaults; see config.env.example
#     for how to override them for other clouds.
#
# Kubeflow's supported install is to apply `kustomize build example` repeatedly
# until the cluster converges (CRDs must be established before the resources
# that use them apply cleanly), so this script retries with backoff.
#
# Object store: since kubeflow/manifests 26.03, SeaweedFS is the upstream
# default S3-compatible artifact store — no custom overlay is required. The
# upstream example ships Service/seaweedfs in the kubeflow namespace.
#
# Configuration (environment variables, highest priority first):
#   KF_VERSION             - kubeflow/manifests git tag (default: 26.03)
#   KF_GPU_TOLERATION_KEY  - taint key to tolerate on GPU nodes
#                            (default: nvidia.com/gpu; set to "" to skip)
#   KF_APISERVER_CIDRS     - comma-separated CIDR(s) for the API server nodes
#                            (default: 192.168.128.0/17 — Linode LKE)
#                            set to "" to skip the NetworkPolicy patch
#   KF_POD_CIDR            - pod network CIDR for the webhook NetworkPolicy patch
#                            (default: 10.2.0.0/16 — Linode LKE / Calico)
#                            set to "" to skip the NetworkPolicy patch
#
# These variables can also be set in platform/config.env (sourced automatically
# if it exists next to this script). CLI env always wins over config.env.
#
# Usage:
#   ./platform/install.sh
#   KF_VERSION=26.03 ./platform/install.sh
#   KF_APISERVER_CIDRS="" KF_POD_CIDR="" ./platform/install.sh   # skip CIDR patch

set -eu

# ---------------------------------------------------------------------------
# Source config.env if present (values are overridden by the environment).
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${SCRIPT_DIR}/config.env" ]; then
  # shellcheck source=/dev/null
  . "${SCRIPT_DIR}/config.env"
fi

# ---------------------------------------------------------------------------
# Defaults — use the no-colon form so an explicit "" disables the feature
# rather than being overridden by the default.
# ---------------------------------------------------------------------------
KF_VERSION="${KF_VERSION-26.03}"
KF_GPU_TOLERATION_KEY="${KF_GPU_TOLERATION_KEY-nvidia.com/gpu}"
KF_APISERVER_CIDRS="${KF_APISERVER_CIDRS-192.168.128.0/17}"
KF_POD_CIDR="${KF_POD_CIDR-10.2.0.0/16}"

# ---------------------------------------------------------------------------
# Preflight: required CLIs must be on PATH.
# ---------------------------------------------------------------------------
for bin in kubectl kustomize git; do
  if ! command -v "$bin" > /dev/null 2>&1; then
    echo "Error: '$bin' not found on PATH." >&2
    echo "  Prerequisites: kubectl, kustomize, git." >&2
    exit 1
  fi
done

# Verify we can talk to the cluster.
if ! kubectl cluster-info > /dev/null 2>&1; then
  echo "Error: cannot reach the cluster. Check your KUBECONFIG / current context." >&2
  exit 1
fi

echo "Installing Kubeflow ${KF_VERSION} …"
echo "  GPU toleration key : ${KF_GPU_TOLERATION_KEY:-<disabled>}"
echo "  API-server CIDRs   : ${KF_APISERVER_CIDRS:-<disabled>}"
echo "  Pod CIDR           : ${KF_POD_CIDR:-<disabled>}"
echo ""

# ---------------------------------------------------------------------------
# Work directory + cleanup.
# ---------------------------------------------------------------------------
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Clone kubeflow/manifests at the requested version.
# ---------------------------------------------------------------------------
echo "Cloning kubeflow/manifests at ${KF_VERSION} …"
git clone --depth 1 --branch "${KF_VERSION}" \
  https://github.com/kubeflow/manifests.git "${WORKDIR}/manifests"

cd "${WORKDIR}/manifests"

# ---------------------------------------------------------------------------
# Build a kustomize overlay on top of the upstream example.
#
# Since kubeflow/manifests 26.03 the upstream example already includes
# SeaweedFS as the default object store; no custom patches are needed for it.
#
# The only overlay content is the optional GPU toleration patch, which adds
# a toleration for the GPU node taint to every Deployment and StatefulSet
# (across all namespaces) so Kubeflow control-plane pods can schedule onto
# tainted GPU nodes when desired.
#
# Overlay layout (inside the cloned tree — kustomize 5.x requires resources
# to be at or below the kustomization root):
#
#   overlay/
#   ├── kustomization.yaml
#   ├── deploy-toleration.yaml   <- (only when GPU_TOL_KEY is set)
#   └── sts-toleration.yaml      <- (only when GPU_TOL_KEY is set)
# ---------------------------------------------------------------------------
OVERLAY="${WORKDIR}/manifests/overlay"
mkdir -p "${OVERLAY}"

TOLERATION_PATCHES=""
if [ -n "${KF_GPU_TOLERATION_KEY}" ]; then
  echo "Creating GPU toleration patches (key=${KF_GPU_TOLERATION_KEY}) …"

  cat > "${OVERLAY}/deploy-toleration.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: placeholder
spec:
  template:
    spec:
      tolerations:
        - key: "${KF_GPU_TOLERATION_KEY}"
          operator: "Exists"
          effect: "NoSchedule"
EOF

  cat > "${OVERLAY}/sts-toleration.yaml" <<EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: placeholder
spec:
  template:
    spec:
      tolerations:
        - key: "${KF_GPU_TOLERATION_KEY}"
          operator: "Exists"
          effect: "NoSchedule"
EOF

  TOLERATION_PATCHES='
patches:
  - path: deploy-toleration.yaml
    target:
      kind: Deployment
  - path: sts-toleration.yaml
    target:
      kind: StatefulSet'
fi

cat > "${OVERLAY}/kustomization.yaml" <<EOF
resources:
  - ../example
${TOLERATION_PATCHES}
EOF

# ---------------------------------------------------------------------------
# Apply loop — convergence may take multiple passes as CRDs register.
# ---------------------------------------------------------------------------
echo "Applying Kubeflow manifests (full platform; this can take 10–20 minutes) …"
attempt=1
max_attempts=30
until kustomize build "${OVERLAY}" | kubectl apply --server-side --force-conflicts -f -; do
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "Error: Kubeflow apply did not converge after ${max_attempts} attempts." >&2
    exit 1
  fi
  echo "Some resources are not ready yet; retrying (${attempt}/${max_attempts}) …"
  attempt=$((attempt + 1))
  sleep 20
done

# ---------------------------------------------------------------------------
# Readiness gate.
# ---------------------------------------------------------------------------
echo "Kubeflow ${KF_VERSION} applied. Waiting for the pipeline API …"
kubectl -n kubeflow rollout status deploy/ml-pipeline --timeout=600s || \
  echo "Note: ml-pipeline not ready yet; check 'kubectl get pods -n kubeflow'."

# ---------------------------------------------------------------------------
# Trainer v2 post-install: apply ClusterTrainingRuntimes.
#
# kubeflow/manifests 26.03 ships Trainer v2 (trainer.kubeflow.org/v1alpha1)
# which requires ClusterTrainingRuntime objects (e.g. torch-distributed) to be
# present before TrainJobs can reference them.
# ---------------------------------------------------------------------------
RUNTIMES_OVERLAY="${WORKDIR}/manifests/applications/trainer/upstream/overlays/runtimes"
if [ -d "${RUNTIMES_OVERLAY}" ]; then
  echo "Applying ClusterTrainingRuntimes overlay …"
  kustomize build "${RUNTIMES_OVERLAY}" | kubectl apply --server-side --force-conflicts -f - || \
    echo "Warning: ClusterTrainingRuntimes overlay failed; TrainJobs may not work." >&2
else
  echo "Warning: ClusterTrainingRuntimes overlay not found at ${RUNTIMES_OVERLAY}; skipping." >&2
fi

# ---------------------------------------------------------------------------
# Networking fix: allow Kubernetes API server to reach webhook pods.
#
# The default-allow-same-namespace-kubeflow-system NetworkPolicy restricts
# ingress to kubeflow-system pods to same-namespace pods only. This blocks
# the API server from calling admission webhooks (jobset-controller-manager,
# kubeflow-trainer-controller-manager), causing TrainJob creation to time out.
#
# We patch the policy to add ipBlock rules for the configured CIDRs. Skip
# the patch if KF_APISERVER_CIDRS or KF_POD_CIDR is explicitly set to "".
# ---------------------------------------------------------------------------
if [ -n "${KF_APISERVER_CIDRS}" ] && [ -n "${KF_POD_CIDR}" ]; then
  echo "Patching kubeflow-system NetworkPolicy (API server → webhook CIDRs) …"

  # Build the JSON ipBlock array from the comma-separated CIDR list + pod CIDR.
  IPBLOCK_JSON=""
  # Convert comma-separated list to newline-separated for iteration.
  OLD_IFS="$IFS"
  IFS=","
  for cidr in ${KF_APISERVER_CIDRS}; do
    # Trim leading/trailing spaces.
    cidr="${cidr# }"
    cidr="${cidr% }"
    IPBLOCK_JSON="${IPBLOCK_JSON},{\"ipBlock\":{\"cidr\":\"${cidr}\"}}"
  done
  IFS="$OLD_IFS"
  IPBLOCK_JSON="${IPBLOCK_JSON},{\"ipBlock\":{\"cidr\":\"${KF_POD_CIDR}\"}}"
  # Strip leading comma.
  IPBLOCK_JSON="${IPBLOCK_JSON#,}"

  kubectl patch networkpolicy default-allow-same-namespace-kubeflow-system \
    -n kubeflow-system \
    --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/ingress\",\"value\":[{\"from\":[{\"podSelector\":{}},${IPBLOCK_JSON}]}]}]" || \
    echo "Warning: NetworkPolicy patch failed; webhooks may not be reachable." >&2
else
  echo "Note: KF_APISERVER_CIDRS or KF_POD_CIDR is empty — skipping NetworkPolicy patch."
  echo "  If TrainJob creation times out with 'context deadline exceeded', patch"
  echo "  the kubeflow-system NetworkPolicy manually to allow API-server traffic."
fi

# ---------------------------------------------------------------------------
# PodSecurity: allow GPU workloads in the kubeflow namespace.
#
# The kubeflow namespace is labeled enforce=restricted by the upstream
# manifests, which blocks GPU training pods (they run as root and need
# unrestricted capabilities). Relabel to privileged for lab use.
# ---------------------------------------------------------------------------
echo "Relabeling kubeflow namespace PodSecurity to privileged …"
kubectl label namespace kubeflow \
  pod-security.kubernetes.io/enforce=privileged \
  --overwrite || \
  echo "Warning: namespace label failed; GPU training pods may be blocked by PodSecurity." >&2

echo ""
echo "Done. Kubeflow ${KF_VERSION} is installed."
echo ""
echo "Access the Central Dashboard:"
echo "  kubectl port-forward -n istio-system svc/istio-ingressgateway 8080:80"
echo "  then open http://localhost:8080 (default: user@example.com / 12341234)"
echo ""
echo "Verify with the smoke-test pipelines:"
echo "  make examples-compile"
echo "  kubectl -n kubeflow port-forward svc/ml-pipeline-ui 8080:80"
echo "  # upload examples/kubeflow-pipelines/hello_pipeline.yaml and run"
