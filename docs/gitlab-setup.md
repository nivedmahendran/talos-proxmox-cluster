# GitLab on the Homelab (production-shaped)

A fully self-hosted GitLab deployed on the Talos/Kubernetes cluster, exposed
over Tailscale with automatic HTTPS, backed by external PostgreSQL, Redis, and
S3-compatible object storage. CI/CD runners run in a dedicated LXC container on
Proxmox.

## Architecture

```
Browser / device on Tailnet
  └─ https://gitlab-gitlab-ingress.tail1b67a1.ts.net
       └─ Tailscale operator Ingress (auto TLS, port 8181 -> workhorse)
            └─ GitLab webservice (Rails + Workhorse)
                 ├─ PostgreSQL (external, StatefulSet on NFS)  - 1126 tables
                 ├─ Redis (external, Deployment on NFS)
                 └─ SeaweedFS S3 (object storage: registry, artifacts, lfs, uploads, packages)

CI/CD runner:
  └─ LXC container 301 on Proxmox (Docker executor) -> registers to GitLab
```

## Components

| Component | Where | Notes |
|---|---|---|
| GitLab v19.5 CE | Helm chart in `gitlab` namespace | webservice, sidekiq, gitaly, registry, kas, shell, toolbox |
| PostgreSQL 16 | StatefulSet in `gitlab-infra` ns | on NFS, `max_locks_per_transaction=1000` |
| Redis 7 | Deployment in `gitlab-infra` ns | on NFS |
| SeaweedFS | Deployment in `gitlab-infra` ns | S3 endpoint on 8333 |
| Tailscale ingress | operator + Ingress | MagicDNS name, auto TLS |
| GitLab Runner | LXC container 301 on pve | Docker executor, registers via NodePort |

## External dependencies (required by GitLab v19+)

Chart v10+ **dropped bundled Redis/PostgreSQL** — they are required external.
Object storage is also required (no bundled solution).

### PostgreSQL (`gitlab-postgres.yaml`)
- StatefulSet + NFS PVC, 1 replica
- Hardened: non-root (UID 999), initContainer chown, emptyDir socket
- **Critical:** `max_locks_per_transaction=1000` via `postgres -c` argument.
  Without this, GitLab's schema load fails with `ERROR: out of shared memory`
  / `max_locks_per_transaction` hint.

### Redis (`gitlab-redis.yaml`)
- Deployment + NFS PVC, `redis-server --appendonly yes`

### SeaweedFS (`gitlab-seaweedfs.yaml`)
- Single-node `weed server -dir=/data -filer -s3`
- S3 on port 8333. Buckets must exist for registry/artifacts/lfs/uploads/packages.

## GitLab Helm values

Key points in `gitlab-values.yaml`:
- `global.hosts.gitlab.name` = the Tailscale MagicDNS name
- `global.hosts.https: true` (so GitLab generates https asset URLs; Tailscale terminates TLS)
- `global.psql` / `global.redis` → external services
- `global.appConfig.object_store` → consolidated S3 connection via a **secret**
  (`connection.secret`), with per-item `bucket` only
- `gitlab.registry.storage.secret` → registry S3 config secret
- disable certmanager, nginx-ingress, prometheus, gatewayApi
- `gitlab.webservice` replicas/resources tuned to cluster

## Gotchas hit (and fixes)

1. **`certmanager-issuer` requires email** → set `installCertmanager: false`
   and a dummy `certmanager-issuer.email`.
2. **Duplicate `global:` YAML keys** → last wins; must merge into one block.
3. **Mixed consolidated + per-item object storage** → use consolidated
   `connection` (via secret) + per-item `bucket` only.
4. **Blank projected secret in webservice** → object storage connection must be
   provided as a secret reference (`connection.secret`), not inline.
5. **Registry `NoSuchBucket`** → create the S3 buckets in SeaweedFS.
6. **Schema load `out of shared memory`** → `max_locks_per_transaction=1000`
   on PostgreSQL. GitLab's `structure.sql` is huge; default (64) is too low.
7. **No CSS (asset redirect)** → the ingress was routing to Rails (port 8080).
   Route to **Workhorse port 8181** (serves static assets).
8. **Login fails (invalid credentials)** → initial root password wasn't effective;
   GitLab's password policy rejected a weak reset password. Set a strong password
   via `gitlab-rails runner`.

## Runner (LXC on Proxmox)

The CI/CD runner runs in a dedicated LXC container on the Proxmox host
(Docker executor), joined to the tailnet so builds reach GitLab over HTTPS
MagicDNS. See [gitlab-runner.md](gitlab-runner.md) for the full setup,
the TUN/DNS requirements, and gotchas.

## Access

- URL: `https://gitlab-gitlab-ingress.tail1b67a1.ts.net`
- Login: `root` (password in the `gitlab-initial-root-password` secret)
