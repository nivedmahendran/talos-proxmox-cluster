---
name: Homelab Triage
description: Diagnose the Talos/Kubernetes homelab stack — Talos node boot issues, PodSecurity/deployment failures, NFS storage, Tailscale networking/ACLs, and self-hosted GitLab. Use when anything breaks on the Proxmox + Talos + K8s + Tailscale + GitLab stack. Symptom→root-cause→fix reference; low-token triage.
---

# Homelab Triage

Fast diagnostic reference for the stack: Proxmox → Talos → Kubernetes →
Tailscale → GitLab (with NFS storage). **Diagnose read-only first**; change
nothing until you have evidence. Grab exact log lines as evidence — don't guess.

## 1. Quick-seek table (symptom → root cause → fix)

| Symptom | Likely root cause | Fix |
|---|---|---|
| Talos VM panics after GRUB: `This program can only be run on AMD64 processors with v2 microarchitecture support` | CPU model too old (`qemu64`) — Talos 1.14 needs x86-64-v2 | set `cpu.type="x86-64-v2-AES"` in Terraform |
| VMs boot to GRUB then nothing; no Talos API (50000) | legacy SeaBIOS; need UEFI | use `bios="ovmf"` + `machine="q35"` + EFI disk |
| Talos dashboard: `failed to validate config ... UnattendedInstallConfig ...` | config built from user-data conflicts with v1.14 multi-doc config | let the Talos provider apply canonical config in maintenance mode; don't hand-build user-data |
| `kubectl` → `localhost:8080 refused` | no kubeconfig set | set `KUBECONFIG` or copy to `~/.kube/config` |
| Pod stuck `Pending`, PVC `Pending` | `WaitForFirstConsumer` storage + unbound claim | check storageclass provisioning; scale app to create consumer |
| `CrashLoopBackOff`: permission denied on data dir | non-root can't write root-owned dir | initContainer `chown` on the shared volume |
| initContainer fails `No such file or directory` | init runs a different image/filesystem | only chown shared volumes, not image paths |
| `out of shared memory` / `max_locks_per_transaction` during GitLab schema load | PG default locks too low | run postgres with `-c max_locks_per_transaction=1000` |
| GitLab login page has no CSS (assets redirect to /users/sign_in) | ingress routed to Rails (8080) instead of static-serving workhorse | route ingress to **workhorse port 8181** |
| GitLab registry `NoSuchBucket` | S3 bucket doesn't exist | create buckets in SeaweedFS |
| GitLab login "Invalid credentials" but user exists | initial root password not effective / weak reset rejected | set strong password via `gitlab-rails runner` |
| Tailscale: `requested tags [tag:k8s] are invalid` | tag not declared/owned in ACL | add `tag:k8s` to `tagOwners` |
| Tailscale ingress proxy stuck `0/2 backends` + `tls: failed to find PEM` | (Talos) API-server-proxy can't read apiserver cert | use subnet router for remote kubectl instead |
| Runner build container can't resolve GitLab MagicDNS | Docker DNS not using Tailscale MagicDNS | set Docker `dns: ["100.100.100.100", ...]` |
| Runner HTTP clone → `403 Nil JSON web token` | GitLab rejects http clone over LAN | use HTTPS MagicDNS URL (not NodePort http) |
| Runner intermittent clone timeout | tailnet path via DERP relay (not direct) | acceptable or expose GitLab to LAN over HTTPS for direct path |

## 2. Talos / node boot

- API is on **TCP 50000** (Talos), k8s API on **6443**.
- Boot state: read serial console (worker VM has `serial_device`) via
  `socat - UNIX-CONNECT:/var/run/qemu-server/<vmid>.serial0`.
- If node pings but API never comes up → boot problem (CPU/firmware), not config.
- Check VM CPU/firmware: `qm config <vmid> | grep -E "cpu|bios|machine"`.

## 3. Kubernetes / workloads

- PodSecurity: Talos default is `restricted`. Non-root image + `securityContext`
  (`allowPrivilegeEscalation:false`, `capabilities.drop:["ALL"]`,
  `runAsNonRoot:true`, `seccompProfile.type:RuntimeDefault`).
- A template change does NOT restart running pods → `kubectl rollout restart` or
  delete the pod.
- PVC deletion blocked while a pod uses it → scale to 0 first.
- Inspect: `kubectl describe pod`, `kubectl logs <pod> -c <c> --previous`,
  `kubectl get events --sort-by=.lastTimestamp`.

## 4. Storage (NFS)

- Local-path needs `privileged` namespace for helper pods (hostPath).
- NFS provisioner is fine under restricted. Never delete the backend dir
  out-of-band while a PVC references it (mount breaks).

## 5. Tailscale

- Operator uses `tag:k8s-operator`; proxies use `tag:k8s`. Both must be in
  `tagOwners` in the ACL.
- ACL `dst` must be `host:port`, tags/IPs, NOT MagicDNS hostnames.
- Subnet router: advertise from pve-host (`tailscale set --advertise-routes=10.10.8.0/22`), approve in console, and clients need `tailscale up --accept-routes=true`.
- MagicDNS: `getent hosts <name>.tail1b67a1.ts.net` to resolve.

## 6. GitLab

- External PostgreSQL/Redis/object-storage are REQUIRED (chart v10+; no bundled).
- Object storage: consolidated `connection` must be a **secret ref**
  (`connection.secret`), per-item only `bucket`.
- Registry storage: secret with S3 config (`gitlab.registry.storage.secret`).
- Assets served by **workhorse (8181)**, not Rails (8080).
- Login: root password policy rejects weak passwords — use a strong one.

## 7. Evidence-first reporting

Always report: symptom → evidence (exact log/status line) → root cause →
fix → verification. This keeps the loop tight and low-token.

## References

- `references/talos-boot.md` — Talos node boot failures (CPU, firmware, config delivery)
- `references/gitlab-fixes.md` — GitLab deployment fixes and the runner setup recap
- `references/tailscale-network.md` — operator/ACL/subnet-router specifics
