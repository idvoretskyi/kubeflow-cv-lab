#!/usr/bin/env sh
# install.sh — Install the full Kubeflow Platform from the upstream kustomize
# manifests onto any GPU-enabled Kubernetes cluster.
#
# Kubeflow's supported install is to apply `kustomize build example` repeatedly
# until the cluster converges (CRDs must be established before the resources
# that use them apply cleanly), so this script retries with backoff.
#
# Object store: since kubeflow/manifests 26.03, SeaweedFS is the upstream
# default S3-compatible artifact store — no custom overlay is required.
#
# Configuration (environment variables, highest priority first):
#
#   KF_VERSION            - kubeflow/manifests git tag (default: 26.03)
#
#   KF_GPU_TOLERATION_KEY - taint key to tolerate on GPU nodes
#                           (default: nvidia.com/gpu; set to "" to skip)
#
#   KF_WEBHOOK_ACCESS     - how to allow the Kubernetes API server to reach
#                           admission webhook pods in kubeflow-system.
#                           The upstream NetworkPolicy restricts ingress to
#                           same-namespace pods only, which blocks API-server
#                           → webhook traffic and causes TrainJob creation to
#                           time out with "context deadline exceeded".
#
#                           Modes (default: auto):
#                             auto  — detect node InternalIPs, apiserver
#                                     endpoint IPs, and per-node podCIDRs at
#                                     runtime; build ipBlock rules from them.
#                                     Falls back to "open" if detection finds
#                                     nothing (e.g. CNI doesn't set podCIDR).
#                             open  — allow all sources (0.0.0.0/0) on the
#                                     webhook port. Bulletproof; fine for labs.
#                             cidrs — use KF_APISERVER_CIDRS / KF_POD_CIDR
#                                     (explicit, for hardened / tested paths).
#                             skip  — leave the NetworkPolicy unpatched (use
#                                     when the cluster already permits it, or
#                                     has no NetworkPolicy enforcement).
#
#   KF_APISERVER_CIDRS    - comma-separated CIDR(s); used only in cidrs mode.
#   KF_POD_CIDR           - pod network CIDR; used only in cidrs mode.
#
# All variables can be set in platform/config.env (sourced automatically if it
# exists next to this script). CLI env always wins over config.env.
# Use platform/presets/<name>.env for named cluster configurations.
#
# Usage:
#   ./platform/install.sh
#   KF_VERSION=26.03 KF_WEBHOOK_ACCESS=open ./platform/install.sh
#   PRESET=lke make platform-install    # sources platform/presets/lke.env

set -eu

# ---------------------------------------------------------------------------
# Source preset then config.env (CLI env wins over both).
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -n "${PRESET:-}" ]; then
  PRESET_FILE="${SCRIPT_DIR}/presets/${PRESET}.env"
  if [ ! -f "${PRESET_FILE}" ]; then
    echo "Error: preset file '${PRESET_FILE}' not found." >&2
    AVAILABLE=$(find "${SCRIPT_DIR}/presets" -name '*.env' -exec basename {} .env \; 2>/dev/null | tr '\n' ' ')
    echo "  Available presets: ${AVAILABLE}" >&2
    exit 1
  fi
  echo "Loading preset: ${PRESET} (${PRESET_FILE})"
  # shellcheck source=/dev/null
  . "${PRESET_FILE}"
fi

if [ -f "${SCRIPT_DIR}/config.env" ]; then
  # shellcheck source=/dev/null
  . "${SCRIPT_DIR}/config.env"
fi

# ---------------------------------------------------------------------------
# Defaults — use the no-colon form so an explicit "" disables the feature.
# ---------------------------------------------------------------------------
KF_VERSION="${KF_VERSION-26.03}"
KF_GPU_TOLERATION_KEY="${KF_GPU_TOLERATION_KEY-nvidia.com/gpu}"
KF_WEBHOOK_ACCESS="${KF_WEBHOOK_ACCESS-auto}"
# KF_APISERVER_CIDRS and KF_POD_CIDR have no built-in defaults;
# they are only required when KF_WEBHOOK_ACCESS=cidrs.

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

if ! kubectl cluster-info > /dev/null 2>&1; then
  echo "Error: cannot reach the cluster. Check your KUBECONFIG / current context." >&2
  exit 1
fi

echo "Installing Kubeflow ${KF_VERSION} …"
echo "  GPU toleration key : ${KF_GPU_TOLERATION_KEY:-<disabled>}"
echo "  Webhook access     : ${KF_WEBHOOK_ACCESS}"
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
# The overlay adds an optional GPU toleration patch to every Deployment and
# StatefulSet so Kubeflow control-plane pods can land on tainted GPU nodes.
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
# Networking: allow Kubernetes API server to reach admission webhook pods.
#
# The upstream default-allow-same-namespace-kubeflow-system NetworkPolicy
# restricts ingress to kubeflow-system to same-namespace pods only. This
# blocks the API server from calling admission webhooks (jobset-controller,
# trainer-controller), causing TrainJob creation to time out with
# "context deadline exceeded".
#
# KF_WEBHOOK_ACCESS controls how we open the policy:
#
#   auto  — detect sources at runtime (node IPs, apiserver endpoint IPs,
#            per-node podCIDRs) and build ipBlock rules. Falls back to open.
#   open  — allow all (0.0.0.0/0). Simple; fine for lab environments.
#   cidrs — use KF_APISERVER_CIDRS / KF_POD_CIDR. Explicit / tested paths.
#   skip  — no patch.
# ---------------------------------------------------------------------------

# Helper: build the kubectl patch from a JSON ipBlock array string and apply.
_patch_netpol() {
  ipblocks_json="$1"
  kubectl patch networkpolicy default-allow-same-namespace-kubeflow-system \
    -n kubeflow-system \
    --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/ingress\",\"value\":[{\"from\":[{\"podSelector\":{}},${ipblocks_json}]}]}]" || \
    echo "Warning: NetworkPolicy patch failed; webhooks may not be reachable from the API server." >&2
}

case "${KF_WEBHOOK_ACCESS}" in

  auto)
    echo "Webhook access: auto — detecting cluster sources …"
    DETECTED_JSON=""

    # 1. Node InternalIPs (covers both worker nodes and, on self-managed
    #    clusters, control-plane nodes that run the API server).
    NODE_IPS="$(kubectl get nodes \
      -o jsonpath='{range .items[*]}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}{end}' \
      2>/dev/null || true)"
    for ip in ${NODE_IPS}; do
      DETECTED_JSON="${DETECTED_JSON},{\"ipBlock\":{\"cidr\":\"${ip}/32\"}}"
    done

    # 2. Kubernetes Service endpoints (the virtual IP(s) the API server
    #    sends webhook calls from on some cluster configurations).
    API_EPS="$(kubectl get endpoints kubernetes -n default \
      -o jsonpath='{range .subsets[*]}{range .addresses[*]}{.ip}{"\n"}{end}{end}' \
      2>/dev/null || true)"
    for ip in ${API_EPS}; do
      DETECTED_JSON="${DETECTED_JSON},{\"ipBlock\":{\"cidr\":\"${ip}/32\"}}"
    done

    # 3. Per-node podCIDRs (set by most CNI plugins; absent on some like
    #    Calico in BGP mode — that is the expected fallback path).
    POD_CIDRS="$(kubectl get nodes \
      -o jsonpath='{range .items[*]}{.spec.podCIDR}{"\n"}{end}' \
      2>/dev/null | grep -v '^$' || true)"
    for cidr in ${POD_CIDRS}; do
      DETECTED_JSON="${DETECTED_JSON},{\"ipBlock\":{\"cidr\":\"${cidr}\"}}"
    done

    # Strip the leading comma.
    DETECTED_JSON="${DETECTED_JSON#,}"

    if [ -n "${DETECTED_JSON}" ]; then
      echo "  Detected sources: applying ipBlock rules …"
      _patch_netpol "${DETECTED_JSON}"
    else
      echo "  No sources detected (CNI may not expose podCIDR); falling back to open …"
      _patch_netpol '{"ipBlock":{"cidr":"0.0.0.0/0"}}'
    fi
    ;;

  open)
    echo "Webhook access: open — allowing all sources on the webhook policy …"
    _patch_netpol '{"ipBlock":{"cidr":"0.0.0.0/0"}}'
    ;;

  cidrs)
    if [ -z "${KF_APISERVER_CIDRS:-}" ] && [ -z "${KF_POD_CIDR:-}" ]; then
      echo "Error: KF_WEBHOOK_ACCESS=cidrs requires KF_APISERVER_CIDRS and/or KF_POD_CIDR to be set." >&2
      echo "  Set them in config.env, a preset file, or as env variables." >&2
      exit 1
    fi
    echo "Webhook access: cidrs — using explicit CIDR configuration …"
    CIDRS_JSON=""
    if [ -n "${KF_APISERVER_CIDRS:-}" ]; then
      OLD_IFS="$IFS"
      IFS=","
      for cidr in ${KF_APISERVER_CIDRS}; do
        cidr="${cidr# }"; cidr="${cidr% }"
        CIDRS_JSON="${CIDRS_JSON},{\"ipBlock\":{\"cidr\":\"${cidr}\"}}"
      done
      IFS="$OLD_IFS"
    fi
    if [ -n "${KF_POD_CIDR:-}" ]; then
      CIDRS_JSON="${CIDRS_JSON},{\"ipBlock\":{\"cidr\":\"${KF_POD_CIDR}\"}}"
    fi
    CIDRS_JSON="${CIDRS_JSON#,}"
    _patch_netpol "${CIDRS_JSON}"
    ;;

  skip)
    echo "Webhook access: skip — leaving NetworkPolicy unpatched."
    echo "  If TrainJob creation times out, re-run with KF_WEBHOOK_ACCESS=auto."
    ;;

  *)
    echo "Error: unknown KF_WEBHOOK_ACCESS value '${KF_WEBHOOK_ACCESS}'." >&2
    echo "  Valid values: auto, open, cidrs, skip." >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# PodSecurity: allow GPU workloads in the kubeflow namespace.
#
# The upstream manifests label kubeflow enforce=restricted, which blocks GPU
# training pods (they run as root and need unrestricted capabilities).
# Relabel to privileged for lab use.
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
