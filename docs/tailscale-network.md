# Tailscale Remote Access (no public IP required)

This documents how the homelab Kubernetes cluster is exposed securely over a
Tailscale tailnet. It provides:

- **App access**: expose a Kubernetes Service over the tailnet with automatic
  HTTPS (Tailscale operator + Ingress).
- **Admin access**: reach the Kubernetes API (`kubectl`) from anywhere via a
  subnet router on the Proxmox host.

Everything works without a public IP, without port-forwarding, and with
least-privilege ACLs.

## Architecture

```
Device on Tailnet (phone/laptop, anywhere)
   └─ Tailscale mesh (WireGuard, encrypted)
        ├─ Tailscale Operator (in-cluster)
        │    └─ Ingress (class: tailscale) → Service → Pod   [app access]
        └─ pve-host as subnet router
             └─ advertises 10.10.8.0/22 → cluster API 10.10.10.200:6443  [kubectl]
```

## Prerequisites

- A Tailscale tailnet (free tier is fine).
- `helm` (v3+) installed.
- The cluster is reachable from the workstation (for `kubectl`).

## 1. OAuth client (required)

The operator provisions nodes into your tailnet, so it needs an OAuth client
with permission to create auth keys.

1. Create an OAuth client at: <https://login.tailscale.com/admin/settings/oauth>
2. Scope: **Auth Keys: Write** (this is the one permission it needs).
3. Copy the **Client ID** and **Client Secret**.

> The operator's proxies need the tag `tag:k8s`; the operator itself uses
> `tag:k8s-operator`. Both must be declared in the ACL (see section 4).

## 2. Install the operator

```bash
helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm repo update

kubectl create namespace tailscale

helm install tailscale-operator tailscale/tailscale-operator \
  --namespace tailscale \
  --set apiServerURL=https://controlplane.tailscale.com \
  --set-string oauth.clientID='<CLIENT_ID>' \
  --set-string oauth.clientSecret='<CLIENT_SECRET>' \
  --set oauth.proxyURL='' \
  --set operatorConfig.serviceType=ClusterIP
```

The operator should appear as a device in the Tailscale admin console
(`tailscale-operator`).

## 3. Expose an app via Ingress

Deploy an app and an Ingress using the `tailscale` IngressClass:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello
spec:
  ingressClassName: tailscale
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: hello
                port:
                  number: 80
```

The operator creates a proxy node, registers it in the tailnet, and provisions
an automatic TLS certificate. The app is reachable at:

```
https://<ingress-name>.<tailnet-name>.ts.net
```

Access it over HTTPS from any device on the tailnet.

## 4. ACLs (least privilege)

The production posture is to allow only your own devices to reach the operator
and the services. A working, least-privilege ACL:

```json
{
  "tagOwners": {
    "tag:k8s-operator": ["autogroup:admin"],
    "tag:k8s": ["autogroup:admin"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": [
        "tag:k8s-operator:*",
        "tag:k8s:443"
      ]
    }
  ]
}
```

Points to remember:

- `tagOwners` must declare **both** tags the operator uses: `tag:k8s-operator`
  (operator itself) and `tag:k8s` (the proxy nodes).
- `src: ["autogroup:member"]` limits access to your own devices.
- `dst` must use **tags/IPs**, not MagicDNS hostnames (hostnames are invalid in
  `dst`).
- If you want a broad allow-all for a homelab, the minimal valid form is an
  `action: accept` rule with `src: ["*"]` and `dst: ["*:*"]`.

## 5. Remote kubectl via subnet router

The Kubernetes API is on `10.10.10.200:6443` (LAN). To reach it from anywhere
without exposing a port, advertise the cluster subnet from the Proxmox host
(`pve-host`, already on the tailnet):

```bash
# on the Proxmox host (pve-host)
tailscale set --advertise-routes=10.10.8.0/22
```

Then approve the route in the Tailscale admin console
(<https://login.tailscale.com/admin/settings/subnets>).

The subnet is `10.10.8.0/22` (it covers `10.10.10.x`). After approval, any
tailnet device routes `10.10.10.*` through `pve-host`, so the existing
kubeconfig (which points at `10.10.10.200:6443`) works from anywhere.

Verify on the host:

```
tailscale status --json   # Self.PrimaryRoutes should include 10.10.8.0/22
```

Requires IPv4 forwarding on the host (`net.ipv4.ip_forward = 1`).

On each client device, enable route acceptance once:

```
sudo tailscale up --accept-routes=true
```

Verify on a client:

```
ip route get 10.10.10.200
# 10.10.10.200 dev tailscale0 table 52   ← routed via tailscale, not local LAN
```

Then the existing kubeconfig works:

```
kubectl --kubeconfig ~/talos-cluster/kubeconfig get nodes
```

## End-to-end verification (confirmed working)

Tested remotely from a network **outside** the home LAN (e.g. a Wi-Fi/tethering
network). The route was delivered via Tailscale and `kubectl` returned all nodes:

```
$ ip route get 10.10.10.200
10.10.10.200 dev tailscale0 table 52 src 100.122.61.7

$ kubectl get nodes
talos-cp-1    Ready    control-plane   41h   v1.36.0
talos-worker-1  Ready  <none>          41h   v1.36.0
talos-worker-2  Ready  <none>          41h   v1.36.0
```

## Known limitation: API-server-proxy on Talos

The Tailscale operator also offers a dedicated API-server proxy (`ProxyGroup`
of type `kube-apiserver`). On Talos this did **not** work out of the box: the
operator could not find the API server's serving certificate/CA (Talos manages
control-plane certs internally and doesn't expose them the way a kubeadm-style
cluster does), so the proxy never obtained its serving cert.

**Workaround:** use the subnet router (section 5) for remote `kubectl` instead.
It's simpler and works reliably with Talos.

## Troubleshooting / gotchas

- **"requested tags [tag:k8s] are invalid"** → add `tag:k8s` to `tagOwners`.
  The operator and its proxies use different tags.
- **"hostport must contain a colon"** → `dst` must be `host:port` (e.g. `*:*`).
- **"action="" is not supported"** → newest schema requires `"action": "accept"`.
- **"unknown field ip"** → `ip` is not a valid rule field in the ACL schema.
- **Empty `tls.crt`** in the ingress/proxy TLS secret → ACME cert never issued;
  check the operator/proxy logs. On Talos, the API-server-proxy hits this
  permanent limitation (see above).

## Teardown

```bash
helm uninstall tailscale-operator --namespace tailscale
kubectl delete ns tailscale
# on pve-host
tailscale set --advertise-routes=
```
