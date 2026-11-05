# GitLab Runner (LXC container on Proxmox)

CI/CD runner for the GitLab instance, running in a **dedicated LXC container**
on the Proxmox host (not inside the Kubernetes cluster). It uses the Docker
executor and is joined to the Tailscale tailnet so it can reach GitLab over its
HTTPS MagicDNS endpoint.

## Why a separate LXC?

- Keeps CI/CD compute off the (small, tight) Kubernetes cluster.
- Docker executor gives isolated, reproducible build environments.
- The runner joins the tailnet so builds can reach GitLab's secure HTTPS route.

## Container details

| Property | Value |
|---|---|
| CTID | 301 |
| Hostname | `gitlab-runner` |
| IP | 10.10.10.241/22 (LAN) |
| Privileged | yes (needed for nested Docker / TUN) |
| Features | `nesting=1` |
| Image | Debian 13 |
| Tailscale | joined, `100.112.225.60` (example) |

## Setup steps

### 1. Create the container

```bash
pct create 301 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
  --hostname gitlab-runner \
  --unprivileged 0 \
  --features nesting=1 \
  --cores 2 --memory 4096 --swap 1024 \
  --rootfs local-lvm:20 \
  --net0 name=eth0,bridge=vmbr0,ip=10.10.10.241/22,gw=10.10.10.1,type=veth \
  --nameserver 10.10.10.1 --onboot 1
pct start 301
```

### 2. Expose the TUN device (required for Tailscale)

Tailscale needs `/dev/net/tun`. Add to the container config
(`/etc/pve/lxc/301.conf`), then reboot:

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,optional,create=file
```

### 3. Install Docker + GitLab Runner

```bash
curl -fsSL https://get.docker.com | sh
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | bash
apt-get install -y gitlab-runner
```

### 4. Join the tailnet

```bash
# start tailscaled (detached), then join with a reusable auth key
setsid nohup tailscaled --state=/var/lib/tailscale/tailscaled.state \
  --socket=/var/run/tailscale/tailscaled.sock >/var/log/tailscaled.log 2>&1 < /dev/null &
tailscale --socket=/var/run/tailscale/tailscaled.sock up \
  --authkey=tskey-auth-... --hostname=gitlab-runner
```

### 5. Point Docker DNS at Tailscale MagicDNS

Build containers must resolve the GitLab MagicDNS hostname:

```json
# /etc/docker/daemon.json
{ "dns": ["100.100.100.100", "1.1.1.1"] }
```

Then `systemctl restart docker`.

### 6. Register the runner

```bash
gitlab-runner register \
  --non-interactive \
  --url https://gitlab-gitlab-ingress.tail1b67a1.ts.net \
  --registration-token <token> \
  --executor docker \
  --docker-image alpine:latest \
  --docker-privileged \
  --description "homelab-docker-runner" \
  --tag-list "docker,homelab"
```

The registration token comes from GitLab Admin → Runners (allow registration).

## How builds reach GitLab

- The runner registers and polls GitLab via its configured URL.
- Build containers clone the repo over **HTTPS MagicDNS** (`https://gitlab-gitlab-ingress.tail1b67a1.ts.net`).
- For that to work, build containers must resolve the hostname (Docker DNS → MagicDNS) and route to it (the runner host is on the tailnet, so NAT carries the traffic).

## Gotchas hit

1. **`/dev/net/tun` missing** → Tailscale can't start. Fix: the LXC mount entry above.
2. **`tailscaled` socket not found** → start it explicitly with `--socket=/var/run/tailscale/tailscaled.sock`.
3. **Build container can't resolve MagicDNS** → set Docker DNS to `100.100.100.100`.
4. **HTTP clone → 403 "Nil JSON web token"** → GitLab rejects http clone over LAN; use the HTTPS MagicDNS URL (not a LAN/NodePort HTTP clone_url).
5. **Intermittent clone timeout** → the runner↔ingress-proxy path may go via Tailscale **DERP relay** (not direct), which can hiccup on sustained transfers. The clone is a small transfer; if it becomes a problem, expose GitLab to the LAN over HTTPS (a TLS proxy on the Proxmox host) for a direct path.

## Verify

```bash
gitlab-runner verify --delete          # shows the runner as alive
# in GitLab: Admin → Runners → "homelab-docker-runner" online=True
```

## Teardown

```bash
pct destroy 301
```
