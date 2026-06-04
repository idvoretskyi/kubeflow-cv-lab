# platform/ — Kubeflow installer

Portable scripts to install and uninstall the full **Kubeflow Platform** (all
components from the upstream `kubeflow/manifests` example) on any conformant
GPU-enabled Kubernetes cluster.

## Prerequisites

| Requirement | Notes |
|---|---|
| Kubernetes cluster | Any conformant distribution (EKS, GKE, AKS, LKE, kubeadm, k3s, …) |
| **NVIDIA GPU operator** | Must be running before `install.sh`; installs drivers, device plugin, and GPU Feature Discovery (GFD). See [GPU operator docs](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html). |
| Default `StorageClass` | Required for Kubeflow PVCs (pipelines DB, SeaweedFS) |
| `kubectl` | Configured with a context pointing at the target cluster |
| `kustomize` | v5.x (`kustomize version`) |
| `git` | To clone `kubeflow/manifests` |

## Quick start

```bash
# Install Kubeflow 26.03 (auto-detects webhook access sources)
make platform-install

# Access the Central Dashboard
kubectl port-forward -n istio-system svc/istio-ingressgateway 8080:80
# open http://localhost:8080  (default creds: user@example.com / 12341234)
```

Or run the script directly:

```bash
./platform/install.sh
```

### For Linode/Akamai LKE (tested reference platform)

```bash
PRESET=lke make platform-install
```

The `lke` preset (`platform/presets/lke.env`) uses `cidrs` mode with the exact
LKE CIDRs, which gives a more precise NetworkPolicy patch than `auto` on LKE
(Calico BGP does not set `.spec.podCIDR` on nodes, so `auto` would fall back to
`open`).

## Uninstall

```bash
make platform-uninstall
# or:
./platform/uninstall.sh
```

## Configuration

All settings live in `platform/config.env` (copy from `config.env.example`).
Environment variables set in the shell take precedence over the file.
Named presets override both when `PRESET=<name>` is set.

| Variable | Default | Description |
|---|---|---|
| `KF_VERSION` | `26.03` | `kubeflow/manifests` git tag to install |
| `KF_GPU_TOLERATION_KEY` | `nvidia.com/gpu` | Taint key on GPU nodes; set to `""` to disable the toleration patch |
| `KF_WEBHOOK_ACCESS` | `auto` | How to open the webhook NetworkPolicy — see below |
| `KF_APISERVER_CIDRS` | _(none)_ | Node/control-plane CIDRs; used only in `cidrs` mode |
| `KF_POD_CIDR` | _(none)_ | Pod network CIDR; used only in `cidrs` mode |

### KF_WEBHOOK_ACCESS modes

The upstream `kubeflow-system` `NetworkPolicy` restricts ingress to
same-namespace pods only. This blocks the Kubernetes API server from calling
admission webhooks (jobset, trainer controllers), causing `TrainJob` creation
to time out with `context deadline exceeded`.

| Mode | Behaviour | When to use |
|---|---|---|
| `auto` **(default)** | Detects node `InternalIP`s, `kubernetes` Service endpoint IPs, and per-node `podCIDR`s at runtime; builds `ipBlock` rules. Falls back to `open` if nothing is detected. | Most clusters; zero-config. |
| `open` | Allows all sources (`0.0.0.0/0`). | Labs where simplicity > precision. |
| `cidrs` | Uses explicit `KF_APISERVER_CIDRS` / `KF_POD_CIDR`. | Hardened setups or named presets. |
| `skip` | Leaves the policy unpatched. | Clusters without NetworkPolicy enforcement, or where API-server ingress is already permitted. |

### Presets

Presets capture the full configuration for a specific cluster type:

```bash
PRESET=lke make platform-install    # Linode/Akamai LKE
```

Preset files live in `platform/presets/<name>.env`. Add your own by copying
`lke.env` as a template. Preset values are overridden by `config.env` and CLI
env vars.

To find the values for a `cidrs`-mode preset on any cluster:

```bash
# Node / API-server CIDR
kubectl get nodes -o wide   # look at INTERNAL-IP; find the containing subnet

# Pod CIDR
kubectl cluster-info dump | grep -m1 cluster-cidr
# or check your CNI DaemonSet config (Calico, Flannel, Cilium, …)
```

## What the installer does

1. Clones `kubeflow/manifests` at `KF_VERSION`.
2. Builds a thin kustomize overlay that adds GPU tolerations to every
   `Deployment` and `StatefulSet` (when `KF_GPU_TOLERATION_KEY` is set).
3. Runs `kustomize build | kubectl apply --server-side` in a retry loop (up to
   30 attempts, 20 s backoff) until the cluster converges.
4. Waits for `ml-pipeline` to become ready.
5. Applies the `ClusterTrainingRuntimes` overlay (Trainer v2 / torch-distributed).
6. Patches `kubeflow-system` `NetworkPolicy` per `KF_WEBHOOK_ACCESS` mode.
7. Relabels the `kubeflow` namespace `PodSecurity` to `privileged` so GPU
   training pods (root + extended capabilities) can run.

## Tested on

- Linode/Akamai LKE (Kubernetes 1.31, Calico BGP CNI, NVIDIA RTX 4000 Ada GPU pool)
- Kubeflow manifests **26.03**

Other distributions should work with `KF_WEBHOOK_ACCESS=auto` (or `open`).
Add a preset to `platform/presets/` for any cluster you test and want to
reproduce reproducibly.
