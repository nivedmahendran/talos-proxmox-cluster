# GitLab deployment fixes and runner recap

## External dependencies (chart v10+)

GitLab v19 **dropped bundled Redis/PostgreSQL** — both are required external.
Object storage is also required (no bundled solution).

- PostgreSQL: StatefulSet on NFS. **Critical:** run with
  `postgres -c max_locks_per_transaction=1000`, else the schema load fails:
  `ERROR: out of shared memory` / `max_locks_per_transaction`.
- Redis: Deployment on NFS (`redis-server --appendonly yes`).
- SeaweedFS S3: `weed server -dir=/data -filer -s3`; create buckets for
  registry/artifacts/lfs/uploads/packages.

## Key Helm values (gitlab-values.yaml)

- `global.hosts.gitlab.name` = the Tailscale MagicDNS name; `global.hosts.https: true`
- `global.psql` / `global.redis` → external service FQDNs
- `global.appConfig.object_store.enabled: true` with `connection.secret` (a
  secret holding the S3 connection) + per-item `bucket` only
- `gitlab.registry.storage.secret` → registry S3 config secret (key `config`)
- `gitlab.webservice` replicas/resources tuned to the cluster

## Gotchas (each was a real fix)

1. `certmanager-issuer` requires an email → `installCertmanager: false` + dummy email.
2. Duplicate `global:` YAML keys → merge into one block.
3. Mixed consolidated + per-item object storage → use consolidated `connection`
   (secret ref) + per-item `bucket` only.
4. Blank projected secret in webservice → object storage connection must be a
   secret ref (`connection.secret`), not inline.
5. Registry `NoSuchBucket` → create S3 buckets in SeaweedFS.
6. Schema load `out of shared memory` → `max_locks_per_transaction=1000`.
7. No CSS (asset redirect) → route ingress to **workhorse port 8181** (not Rails 8080).
8. Login fails → root password policy rejects weak passwords; set a strong one.

## Reset root password

```bash
kubectl -n gitlab exec deployment/gitlab-toolbox -c toolbox -- \
  gitlab-rails runner "u=User.find_by(username:'root'); u.password='Strong!Pass'; u.password_confirmation='Strong!Pass'; u.save!"
```

## Runner (LXC on Proxmox)

- CT 301, privileged, Docker + `gitlab-runner`.
- Needs `/dev/net/tun` (add LXC mount entry) for Tailscale.
- Join tailnet with `tailscale up --authkey=...`.
- Docker DNS → `100.100.100.100` so build containers resolve MagicDNS.
- Register with `gitlab-runner register --url https://<gitlab-magicdns> --registration-token <token> --executor docker`.
- Use the HTTPS MagicDNS URL for clones (HTTP/NodePort clone gives `403 Nil JSON web token`).
- Intermittent clone timeout = DERP relay path; expose GitLab to LAN over HTTPS for a direct path if needed.
