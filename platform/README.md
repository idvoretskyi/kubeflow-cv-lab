# platform/ — Kubeflow installer

Portable scripts to install and uninstall the full **Kubeflow Platform** (all
components from the upstream `kubeflow/manifests` example) on any GPU-enabled
Kubernetes cluster.

Derived from the Linode/Akamai LKE-specific installer in
[`akamai-lke-gpu-cluster`](https://github.com/idvoretskyi/linode-gpu-k8s) and
rewritten to be cloud-neutral.

## Prerequisites

| Requirement | Notes |
|---|---|
| Kubernetes cluster | Any distribution (EKS, GKE, AKS, LKE, kubeadm, …) |
| NVIDIA GPU operator | Installed and ready — **not** managed by this repo; see your cloud's docs or the [GPU operator Helm chart](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html) |
| Default `StorageClass` | Required for Kubeflow PVCs (pipelines DB, SeaweedFS) |
| `kubectl` | Configured with a context pointing at the target cluster |
| `kustomize` | v5.x (`kustomize version`) |
| `git` | To clone `kubeflow/manifests` |

## Quick start

```bash
# 1. Copy and edit config (uses Linode/LKE defaults if you skip this step)
cp platform/config.env.example platform/config.env
$EDITOR platform/config.env   # set CIDRs for your cloud if not LKE

# 2. Install
make platform-install

# 3. Access the Central Dashboard
kubectl port-forward -n istio-system svc/istio-ingressgateway 8080:80
# open http://localhost:8080  (default creds: user@example.com / 12341234)
```

Or run the script directly:

```bash
./platform/install.sh
```

## Uninstall

```bash
make platform-uninstall
# or:
./platform/uninstall.sh
```

## Configuration

All settings live in `platform/config.env` (copy from `config.env.example`).
Environment variables set in the shell take precedence over the file.

| Variable | Default | Description |
|---|---|---|
| `KF_VERSION` | `26.03` | `kubeflow/manifests` git tag to install |
| `KF_GPU_TOLERATION_KEY` | `nvidia.com/gpu` | Taint key on GPU nodes; set to `""` to disable the toleration patch |
| `KF_APISERVER_CIDRS` | `192.168.128.0/17` | Comma-separated CIDR(s) of API-server / control-plane nodes |
| `KF_POD_CIDR` | `10.2.0.0/16` | Pod network CIDR |

### Portability: CIDR patch

The upstream `kubeflow-system` `NetworkPolicy` blocks the Kubernetes API server
from reaching admission webhook pods (jobset, trainer controllers). Without a
patch, `TrainJob` creation times out with `context deadline exceeded`.

The installer patches the policy to add `ipBlock` rules for `KF_APISERVER_CIDRS`
and `KF_POD_CIDR`. **The defaults are correct for Linode/Akamai LKE with
Calico.** For other clouds:

```bash
# Find node IPs (API-server CIDR)
kubectl get nodes -o wide   # look at INTERNAL-IP; find the containing subnet

# Find pod CIDR
kubectl cluster-info dump | grep -m1 cluster-cidr
# or check your CNI DaemonSet config
```

Set `KF_APISERVER_CIDRS=""` and `KF_POD_CIDR=""` to skip the patch entirely
(e.g. if your cluster already allows API-server ingress to all pods).

## What the installer does

1. Clones `kubeflow/manifests` at `KF_VERSION`.
2. Builds a thin kustomize overlay that adds GPU tolerations to every
   `Deployment` and `StatefulSet` (when `KF_GPU_TOLERATION_KEY` is set).
3. Runs `kustomize build | kubectl apply --server-side` in a retry loop (up to
   30 attempts with 20 s backoff) until the cluster converges.
4. Waits for `ml-pipeline` to become ready.
5. Applies the `ClusterTrainingRuntimes` overlay (Trainer v2 / torch-distributed).
6. Patches `kubeflow-system` `NetworkPolicy` for API-server → webhook access.
7. Relabels the `kubeflow` namespace `PodSecurity` to `privileged` so GPU
   training pods (root + extended capabilities) can run.

## Tested on

- Linode/Akamai LKE (Kubernetes 1.31, Calico CNI, NVIDIA A100 GPU pool)
- Kubeflow manifests **26.03**

Other distributions should work; adjust CIDRs and the GPU pool label in
`config.env` as needed.
