# NFS Storage for Kubernetes

This documents how the cluster gets **shared, production-shaped storage** via an
NFS server running in a lightweight LXC container on the Proxmox host, exposed
to Kubernetes through the `nfs-subdir-external-provisioner`.

## Why NFS instead of local-path

| | local-path | NFS |
|---|---|---|
| Data location | on one worker node | on the NFS server (separate) |
| Survives worker loss | ❌ | ✅ |
| PodSecurity impact | requires `privileged` for helper pods | works under restricted/baseline |
| Use case | scratch / learning | real shared storage |

## Architecture

```
Kubernetes pod
  └─ PVC (storageClassName: nfs-client)
       └─ nfs-subdir-external-provisioner (Deployment)
            └─ NFS mount → 10.10.10.240:/srv/nfs/k8s
                 └─ LXC container "nfs" (CT 300) on Proxmox host
                      └─ /srv/nfs/k8s (directory on the container's disk)
```

## 1. NFS server (LXC on Proxmox)

The NFS server runs in an LXC container on the Proxmox host. It must be a
**privileged** container: the kernel NFS server needs to mount
`/proc/fs/nfsd` and `/run/rpc_pipefs`, which is not permitted in an
unprivileged container.

Create the container (Debian 13):

```bash
pct create 300 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
  --hostname nfs \
  --unprivileged 0 \
  --features nesting=1 \
  --cores 1 --memory 1024 --swap 512 \
  --rootfs local-lvm:20 \
  --net0 name=eth0,bridge=vmbr0,ip=10.10.10.240/22,gw=10.10.10.1,type=veth \
  --nameserver 10.10.10.1 \
  --onboot 1
pct start 300
```

Inside the container, install and configure NFS:

```bash
pct exec 300 -- bash -c 'apt-get update && apt-get install -y nfs-kernel-server'
pct exec 300 -- bash -c 'mkdir -p /srv/nfs/k8s && chmod 777 /srv/nfs/k8s'
# add export
pct exec 300 -- bash -c 'echo "/srv/nfs/k8s 10.10.10.0/22(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports'
pct exec 300 -- bash -c 'exportfs -ra'
pct exec 300 -- systemctl enable --now nfs-server
```

Verify:

```bash
pct exec 300 -- showmount -e localhost
# /srv/nfs/k8s 10.10.10.0/22
```

> Note: `no_root_squash` lets root inside the cluster's helper/init containers
> write to the share. This is a deliberate tradeoff for a homelab.

## 2. NFS provisioner (on the cluster)

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/nfs-subdir-external-provisioner/master/deploy/rbac.yaml
```

Deploy the provisioner with the NFS server details (patch `NFS_SERVER` and
`NFS_PATH`, and the `nfs` volume):

```yaml
# deployment (abridged)
env:
  - name: PROVISIONER_NAME
    value: k8s-sigs.io/nfs-subdir-external-provisioner
  - name: NFS_SERVER
    value: 10.10.10.240
  - name: NFS_PATH
    value: /srv/nfs/k8s
volumes:
  - name: nfs-client-root
    nfs:
      server: 10.10.10.240
      path: /srv/nfs/k8s
```

StorageClass:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-client
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner
parameters:
  archiveOnDelete: "false"
```

## 3. Using it

A PVC that requests `storageClassName: nfs-client` gets a directory created on
the NFS server automatically:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: nfs-client
```

The provisioner creates a subdirectory under `/srv/nfs/k8s` named after the
claim (e.g. `default-my-data-pvc-<uid>`).

## Key operational facts

- **Delete the PVC, not the directory.** Deleting the backend directory while
  a PVC references it breaks the NFS mount (kubelet reports "No such file or
  directory"). Always delete through Kubernetes.
- **PVC deletion is protected** while a pod uses it (`pvc-protection`
  finalizer). Scale the workload to 0 first, then delete the PVC.
- **Reclaim policy is `Delete`** — deleting the PVC removes the data.
- The provisioner pod itself triggers a PodSecurity warning (its NFS volume
  mount isn't "restricted" compliant). It still runs; hardening it is optional.
