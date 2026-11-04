# Application Deployment Patterns on this Cluster

This captures the deployment patterns demonstrated on this cluster, including a
full **stateful** application (PostgreSQL on NFS). It's a reference for what
works and the common pitfalls.

## The basic recipe: Deployment + Service

- **Deployment** — declaratively runs N identical pods, keeps them alive, and
  supports rolling updates / rollbacks.
- **Service** — a stable name/IP that load-balances to the pods (via `selector`
  matching pod labels).
- **Namespace** — scope/logical grouping.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: learn
spec:
  replicas: 2
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: app
          image: nginxinc/nginx-unprivileged:1.27-alpine
          ports:
            - containerPort: 8080
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  namespace: learn
spec:
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 8080
```

## PodSecurity compliance (Talos default is `restricted`)

Talos enforces the `restricted` Pod Security standard. A container that does
not opt in fails/emits warnings. Two ways to comply:

1. **Choose images that run as non-root** (e.g. `nginx-unprivileged` instead of
   stock nginx), and set a securityContext.
2. For images that need a root-owned writable directory, use an **initContainer**
   (running as root) to `chown` a shared volume before the main container runs.

```yaml
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
  runAsNonRoot: true
  runAsUser: 999
  seccompProfile:
    type: RuntimeDefault
```

Common trap: an initContainer runs a **different image** (e.g. busybox) with its
own filesystem — it cannot chown paths that only exist inside the main image.
Only shared **volumes** are reachable from both.

## ConfigMaps and Secrets

- **ConfigMap** — non-secret config. Can be mounted as a volume (updates
  propagate without restart, with kubelet polling ~1 min) or injected as env
  vars (fixed at container start).
- **Secret** — sensitive data, stored base64 (base64 is not encryption!). Values
  are referenced by `secretKeyRef` / `configMapKeyRef`.

```yaml
env:
  - name: MY_SECRET_VALUE
    valueFrom:
      secretKeyRef:
        name: my-secret
        key: my-pass.txt
```

## Stateful application: PostgreSQL on NFS

A database needs **stable identity** and **stable storage**, which is what a
**StatefulSet** gives:

- stable pod names (`postgres-0`, …)
- a headless Service (`clusterIP: None`) for stable per-pod DNS
- `volumeClaimTemplates` — each pod gets its own PVC

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: postgres
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      initContainers:
        - name: fix-perms
          image: busybox:1.36
          command: ["sh", "-c", "chown -R 999:999 /var/lib/postgresql/data /var/run/postgresql"]
          securityContext:
            runAsUser: 0
          volumeMounts:
            - name: pg-data
              mountPath: /var/lib/postgresql/data
            - name: pg-socket
              mountPath: /var/run/postgresql
      containers:
        - name: postgres
          image: postgres:16-alpine
          env:
            - name: POSTGRES_USER
              valueFrom: { secretKeyRef: { name: pg-secret, key: POSTGRES_USER } }
            - name: POSTGRES_PASSWORD
              valueFrom: { secretKeyRef: { name: pg-secret, key: POSTGRES_PASSWORD } }
            - name: POSTGRES_DB
              valueFrom: { secretKeyRef: { name: pg-secret, key: POSTGRES_DB } }
          volumeMounts:
            - name: pg-data
              mountPath: /var/lib/postgresql/data
            - name: pg-socket
              mountPath: /var/run/postgresql
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
            runAsNonRoot: true
            runAsUser: 999
            seccompProfile: { type: RuntimeDefault }
      volumes:
        - name: pg-socket
          emptyDir: {}
  volumeClaimTemplates:
    - metadata:
        name: pg-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
        storageClassName: nfs-client
```

Postgres gotchas we hit:

1. **`/var/lib/postgresql/data` permission** — NFS directory starts root-owned.
   Fix with an initContainer `chown -R 999:999` on the mounted volume.

2. **`/var/run/postgresql` socket dir** — the entrypoint chmods it ( and it's
   not writable as non-root, and it's not part of the shared data volume. Fix:
   mount an `emptyDir` at `/var/run/postgresql` and chown it in the initContainer.

3. **Stale / partially-initialized data** — `POSTGRES_DB` only applies during a
   *fresh* `initdb`. If a prior (partial) initialization left files on the
   volume, the new pod skips init and `appdb` never gets created. Give it a
   clean volume.

4. **Deleting the PVC while a pod uses it** — blocked by the `pvc-protection`
   finalizer. Scale the StatefulSet to 0, delete the PVC, then scale back.

## Lifecycle / rollout notes

- Changing a Deployment/StatefulSet template does NOT affect running pods — you
  must roll them (`kubectl rollout restart`, or delete the pod).
- `kubectl rollout history` / `rollout undo` — view and revert revisions.
- `kubectl annotate deployment <name> kubernetes.io/change-cause="..."` — label
  a revision so history is self-documenting.

## Exposing externally (MetalLB)

Change a Service to `LoadBalancer` and MetalLB assigns it a LAN IP from the
configured pool:

```bash
kubectl patch svc my-app -p '{"spec":{"type":"LoadBalancer"}}'
kubectl get svc my-app   # watch EXTERNAL-IP
```
