# Tailscale networking specifics

## Operator

- Install via Helm (`tailscale/tailscale-operator`). Needs an OAuth client with
  **Auth Keys: Write** scope.
- The operator uses the tag `tag:k8s-operator`; the proxy nodes it creates use
  `tag:k8s`. **Both must be declared in `tagOwners`** in the ACL.

## Ingress / app exposure

- Ingress class `tailscale` → the operator provisions a proxy node, registers a
  MagicDNS name, and issues an automatic TLS cert (ACME). App served over HTTPS
  with no public IP.
- Example: `https://<ingress>-<ns>-ingress.tail1b67a1.ts.net`.

## ACLs

- Least-privilege example:
  ```json
  { "tagOwners": {
      "tag:k8s-operator": ["autogroup:admin"],
      "tag:k8s": ["autogroup:admin"]
    },
    "acls": [{ "action": "accept", "src": ["autogroup:member"],
               "dst": ["tag:k8s-operator:*", "tag:k8s:443"] }] }
  ```
- `dst` must be tags/IPs/`host:port`, never MagicDNS hostnames.
- Older/newer schema quirk: rules need `"action": "accept"` and `dst` of the
  form `*:*` for allow-all.

## Subnet router (remote kubectl)

- On pve-host: `tailscale set --advertise-routes=10.10.8.0/22`
  (the cluster subnet; /22 covers 10.10.10.x).
- Approve the route in the admin console (Subnets).
- Clients: `sudo tailscale up --accept-routes=true`.
- Verify: `tailscale status --json` → `Self.PrimaryRoutes` includes the subnet;
  `ip route get 10.10.10.200` should show `dev tailscale0`.

## MagicDNS

- Resolve with `getent hosts <name>.tail1b67a1.ts.net`.
- Docker/DNS clients need DNS pointed at `100.100.100.100`.

## Known limitation

- The API-server-proxy (`ProxyGroup` type `kube-apiserver`) fails on Talos:
  the operator can't find the apiserver serving cert (`tls: failed to find PEM`)
  because Talos manages control-plane certs internally. **Use the subnet router**
  for remote kubectl instead.
