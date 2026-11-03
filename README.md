# Talos Kubernetes cluster on Proxmox (Terraform)

A reproducible, infrastructure-as-code setup that provisions a Talos Linux
Kubernetes cluster on a single Proxmox VE host using Terraform.

## Cluster topology

| Node | Role | IP | vCPU | RAM | Disk |
| --- | --- | --- | --- | --- | --- |
| `talos-cp-1` | control-plane | `10.10.10.200` | 2 | 4 GiB | 40 GB |
| `talos-worker-1` | worker | `10.10.10.203` | 2 | 4 GiB | 60 GB |
| `talos-worker-2` | worker | `10.10.10.204` | 2 | 4 GiB | 60 GB |

- **Talos Linux** `v1.14.5` (nocloud platform image from the Image Factory,
  with the `qemu-guest-agent` schematic)
- **Kubernetes** `v1.36.0` (CNI: Flannel, default)
- API endpoint: `https://10.10.10.200:6443`
- Addressing: static IPs in `10.10.10.0/22` (gateway `10.10.10.1`)

### Why these settings matter

These three settings were the difference between a healthy cluster and nodes
that booted but never came up (see `docs/troubleshooting.md`):

1. **CPU model:** `x86-64-v2-AES` — Talos 1.14 binaries require the
   x86-64-v2 microarchitecture. The default `qemu64` model makes the Talos
   `init` crash immediately after GRUB.
2. **Firmware:** UEFI (`bios = "ovmf"`, `machine = "q35"`, EFI disk).
   SeaBIOS is not a supported path for these images.
3. **Config delivery:** nodes boot into **maintenance mode** and the
   `siderolabs/talos` provider applies the full, canonical machine config
   (multi-document v1alpha1 bundle), then bootstraps. Hand-built single-doc
   user-data is not used — it conflicts with Talos 1.14's split config
   documents (`UnattendedInstallConfig`, `HostnameConfig`, `ResolverConfig`).

## Repository layout

```
.
├── README.md
├── docs/
│   └── troubleshooting.md
└── terraform/
    ├── providers.tf     # bpg/proxmox + siderolabs/talos
    ├── variables.tf
    ├── main.tf          # VMs + Talos bootstrap
    ├── outputs.tf
    └── .gitignore
```

## Prerequisites

- Proxmox VE 9.x node (this was built against 9.1.2), reachable on
  `https://<host>:8006/`
- A Proxmox **API token** with full privileges (root@pam token is simplest)
- `terraform` >= 1.5, `talosctl` and `kubectl` matching Talos v1.14.x
- Internet access from the Proxmox host (to download the Talos image)

### One-time Proxmox preparation

The Talos image is downloaded with content type `import` into a dedicated
datastore. Create it once on the Proxmox host:

```bash
# on the Proxmox host (root shell)
pvesm add dir local-import --path /var/lib/vz/imports --content import
```

Verify it exists and accepts `import` content:

```bash
pvesm status -content import
# Name          Type Status     Total   Used Available %
# local-import  dir  active     ...
```

Create an API token for Terraform (privilege separation **off** so it can
read datastores):

```bash
pveum user token add root@pam terraform-full --privsep 0
# copy the token value — it is shown only once
```

## Deploy

```bash
cd terraform

# Credentials via environment (never commit these)
export PROXMOX_VE_USERNAME="root@pam"
export PROXMOX_VE_API_TOKEN="root@pam!terraform-full=<token-value>"

terraform init
terraform plan
terraform apply
```

On success you get:

```
cluster_endpoint = "https://10.10.10.200:6443"
control_plane_nodes = ["10.10.10.200"]
worker_nodes = ["10.10.10.203", "10.10.10.204"]
kubeconfig = <sensitive>
talosconfig = <sensitive>
```

Save the outputs:

```bash
terraform output -raw kubeconfig > ~/kubeconfig
terraform output -raw talosconfig > ~/talosconfig
```

## Using the cluster

```bash
alias k="kubectl --kubeconfig ~/kubeconfig"
k get nodes
k get pods -A

# Talos admin
talosctl --talosconfig ~/talosconfig --endpoints 10.10.10.200 \
  --nodes 10.10.10.200 service
```

## Teardown

```bash
terraform destroy
```

This removes the VMs and their disks. The `local-import` datastore and API
token are left in place (they are host-level prerequisites).

## Security notes

- No secrets are stored in this repository. Credentials are passed via
  environment variables at apply time.
- Terraform state (`terraform.tfstate*`) contains cluster secrets (CA keys,
  tokens) and is gitignored.
- `kubeconfig` / `talosconfig` / machine configs are never committed.
