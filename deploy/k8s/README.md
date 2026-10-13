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
because these causes need changes in different files:

| Symptom | Cause | Fix |
|---|---|---|
| `phase=Pending`, no `scheduling:` line | A PVC is `Pending` | see *Storage* below |
| `phase=Pending`, `scheduling:` says the node selector did not match | Architecture or node pin | see *Node selection* below |
| `ImagePullBackOff` / `ErrImagePull` | The image is not pullable | see *the image* above |
| `CrashLoopBackOff`, log says `ttyd: invalid value for port: tcp://…` | Kubernetes service links set `PI_CAGE_PORT` to the Service's ClusterIP | `core.yaml` sets `enableServiceLinks: false` — **do not remove it** |

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

## What the NetworkPolicies assume — and how not to get it wrong

`networkpolicy.yaml` denies every internal range **by destination address**. The
whole design rests on the `except` list covering wherever *your* cluster puts its
Pods and Services.

**The shipped list is a template**, not a universal truth. It carries the three
private ranges (`10/8`, `172.16/12`, `192.168/16`), which is most clusters — but
EKS, GKE and plenty of self-hosted setups choose their own, and a cluster outside
those three would be **left wide open while still looking correctly configured**.

Do not work it out by hand. Ask the script:

```bash
bash verify-network-boundary.sh --suggest-excepts   # prints a list sized for your cluster
bash verify-network-boundary.sh                     # fails if coverage is missing
```

`--suggest-excepts` reads your nodes' `podCIDR` and the `kubernetes` Service
ClusterIP and prints a ready-to-paste `except` block. If `podCIDR` is empty (some
CNIs do not populate it), it tells you to look at
`--cluster-cidr` / `--service-cluster-ip-range` on the controller manager
instead.

Preflight in `verify-network-boundary.sh` then **tests every one of those
addresses against the loaded policy** and fails with the exact entries to add.
That check is the reason this is safe to hand to someone else's cluster: checking
only that the well-known ranges are present would report a clean boundary on a
cluster whose `198.19.0.0/16` Pod CIDR was wide open — a silent false green,
which is worse than a false red.

**Never add `198.18.0.0/15`.** On a network running Clash/OpenClash fake-ip DNS,
every external name resolves into that range; listing it excludes the entire
public internet, model API included. The script fails the run if it finds it.

## Node selection

`core.yaml` sets **no `nodeSelector`**. An earlier revision pinned
`kubernetes.io/arch: arm64`, which is silently fatal everywhere else: the Pod sits
`Pending` with *"didn't match Pod's node affinity/selector"* and reads like a
capacity problem.

If you build for a single architecture only, add a selector or the scheduler may
place the Pod on a node that cannot run the image:

```yaml
# kustomization.yaml
patches:
  - target: { kind: Deployment, name: pi-cage }
    patch: |-
      - op: add
        path: /spec/template/spec/nodeSelector
        value: { kubernetes.io/arch: arm64 }
```

## Different CNIs

`verify-network-boundary.sh` detects the policy engine (Calico, Cilium, Antrea,
aws-node, kube-router). If yours is not in that list, name it rather than letting
the script conclude "no boundary":

```bash
PI_CAGE_POLICY_ENGINE=<daemonset> PI_CAGE_POLICY_ENGINE_NS=<ns> bash verify-network-boundary.sh
```

Note that **flannel does not implement NetworkPolicy at all** — every policy in
this directory is inert on a flannel cluster, and no amount of verification will
change that.

