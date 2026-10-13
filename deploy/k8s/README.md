# Deploying pi-cage on Kubernetes

## Read this first: there is no published image

`core.yaml` references `ghcr.io/zmhhaha/pi-cage:latest`. **That image does not
exist.** If you `kubectl apply -k` without changing it, you get a Deployment, a
Service, and three NetworkPolicies — and a Pod stuck in `ImagePullBackOff`. The
boundary policies apply fine; the container never starts.

`kustomization.yaml` has an `images:` block for exactly this. **Set it before
you apply.** Pick one of the three paths below.

---

## Option 1 — publish to GHCR (the project's intended path)

Once a release image exists, this becomes a no-op.

```bash
./build.sh --multiarch --push        # builds amd64 + arm64 and pushes
```

`build.sh` needs `REGISTRY` and `IMAGE` set for that to land in your namespace —
see `config/build.example.env` in the repository root. Until a release exists,
use option 2 or 3.

## Option 2 — your own registry (recommended for a private cluster)

```bash
# On the machine where you built it:
tag="$(date -u +%Y%m%dT%H%M%SZ)"
docker tag  pi-cage:latest  my-registry.local:5000/pi-cage:"$tag"
docker tag  pi-cage:latest  my-registry.local:5000/pi-cage:latest
docker push my-registry.local:5000/pi-cage:"$tag"
docker push my-registry.local:5000/pi-cage:latest
```

Then in `kustomization.yaml`:

```yaml
images:
  - name: ghcr.io/zmhhaha/pi-cage
    newName: my-registry.local:5000/pi-cage
    newTag: "20261013T060112Z"     # prefer the timestamp tag over :latest
```

Apply:

```bash
kubectl apply -k deploy/k8s
kubectl -n pi-cage rollout status deployment/pi-cage --timeout=300s
```

## Option 3 — the image exists only on one node

If you built locally and did not push anywhere, the image lives in that node's
container runtime and **nowhere else**. Kubernetes will schedule the Pod onto
whatever node matches `nodeSelector` — which is only `kubernetes.io/arch: arm64`
— so it will usually land somewhere that cannot pull it.

Two things are required: use the image under a name the node already has, and
pin the Pod to that node.

`core.yaml`'s default `imagePullPolicy: IfNotPresent` already avoids a doomed
pull *if the name matches exactly*.

```yaml
# kustomization.yaml
images:
  - name: ghcr.io/zmhhaha/pi-cage
    newName: pi-cage          # the local name, no registry prefix
    newTag: latest

patches:
  - target: { kind: Deployment, name: pi-cage }
    patch: |-
      - op: add
        path: /spec/template/spec/nodeSelector/kubernetes.io~1hostname
        value: the-node-with-the-image
```

> Note the `~1` escaping: a `/` in a JSON-patch path must be written `~1`.
> `kubernetes.io/hostname` therefore becomes `kubernetes.io~1hostname`.

This is fine for trying it out and wrong for anything real. A released
deployment should name an image any node can pull.

---

## After it is running

```bash
kubectl -n pi-cage get pods
kubectl -n pi-cage logs deploy/pi-cage -c pi-cage --tail=50
bash verify-network-boundary.sh --explain   # print the criteria; touches nothing
bash verify-network-boundary.sh             # end-to-end; exit 0 is a pass
```

`verify-network-boundary.sh` **refuses to report a verdict at all** when there is
no Pod scheduled, and when the cluster's policies no longer match its expectation
table. That is deliberate: a green run that was never actually probing anything
is worse than no run. When there is no Pod it also prints why — which matters,
because the two common causes need changes in different files:

| Symptom | Cause | Fix |
|---|---|---|
| `phase=Pending`, no `scheduling:` line | A PVC is `Pending` | see *Storage* below |
| `ImagePullBackOff` / `ErrImagePull` | The image is not pullable | see *the image* above |

## Storage

**`storageClassName` is deliberately omitted** from both PVCs in `core.yaml`, so
the cluster's default StorageClass is used. Hard-coding a class name — even a
common-looking one like `standard` — is a trap: on a cluster without that class
the PVC stays `Pending` for ever, the Pod never gets scheduled, and the failure
presents as a scheduling problem rather than a storage one.

Single-writer volumes, so `ReadWriteOnce` on both. That is correct: one Pod owns
each, and the Deployment uses `strategy: Recreate` so two never contend.

Check what you have:

```bash
kubectl get storageclass
kubectl -n pi-cage get pvc
```

If your cluster has **no default** StorageClass, name one explicitly:

```yaml
# deploy/k8s/core.yaml, in both PVC specs
spec:
  storageClassName: your-rbd-class
```

If you need the two Pods to share a workspace (you do not, in the default
single-container design), that requires a `ReadWriteMany` class instead.

## Reaching the web terminal

Nothing can reach port 7681 until you label whatever fronts it:

```bash
kubectl -n <proxy-namespace> label pod <proxy-pod> pi-cage-client=true
```

`proxy-ingress` admits only that label. `pi-cage` does not ship an
authenticating proxy — see the README section *Serving it to anyone else*, and
do not expose the port directly.

## What the NetworkPolicies assume

`networkpolicy.yaml` denies every internal range by destination address. If your
cluster uses Pod or Service CIDRs outside `10.0.0.0/8`, `172.16.0.0/12` or
`192.168.0.0/16`, **add them to the `except` list** — the whole design rests on
those ranges covering your cluster.

And never add `198.18.0.0/15`. On a network running Clash/OpenClash fake-ip DNS,
every external name resolves into that range; listing it excludes the entire
public internet. `verify-network-boundary.sh` fails the run if it finds it.
