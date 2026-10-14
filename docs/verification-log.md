# Verification log

A record of what has actually been checked, on what, and when. Claims in the
README are only as good as this file.

**If you run one of the verification scripts, add a line.** A project whose whole
pitch is verifiable isolation should not be asking you to take its word for it.

---

## 2026-10-13 — `linux/arm64`, maintainer's Docker host

Built with `./build.sh` on an ARM64 host. Image `pi-cage:20261013T060112Z`.

### Build

| Check | Result |
|---|---|
| Base image architecture asserted | ✅ `arm64` |
| Base image pinned to digest | ✅ `node@sha256:d6aa754f16b3197301…` |
| Node version ≥ 22.19.0 (`engines`) | ✅ |
| `ttyd` static release downloaded + `sha256sum -c` | ✅ 1.7.7, both architecture digests verified |
| Pi installed at the exact pinned version | ✅ `@earendil-works/pi-coding-agent@0.99.2` |
| `pi` runnable on `PATH` | ✅ |
| Every `ttyd` flag `serve` depends on | ✅ `--interface --port --writable --max-clients --check-origin --auth-header` |
| No Docker socket present in the build context | ✅ |

**One failure, now fixed:** the build originally failed at the tooling step
because Debian bookworm has no `ttyd` package. See the README section *Where
`ttyd` comes from (and why not `apt`)*.

### Container hardening (`./verify-hardening.sh`)

| Section | Result |
|---|---|
| A. Image properties (uid, entrypoint, default command) | ✅ 3/3 |
| B. Reference run configuration declares the hardening | ✅ 9/9 |
| C. Runtime measurement on a container | ✅ 6/6 |
| D. Fail-closed refusals and absences | ✅ 4/4 |

Section C is the one that matters — it started a container with the reference
flags and measured the result:

- read-only root filesystem **enforced**
- all capabilities **dropped**
- `no-new-privileges` **enforced**
- **no Docker socket mounted**
- **no host system paths mounted**
- **no host Docker data directory mounted**

Section D confirmed these are actually refused: a non-loopback bind without
opt-in, a public bind with authentication disabled, an unknown mode. Plus: the
image contains no Docker client.

**One false failure, now fixed:** section B initially reported `FAIL no Docker
socket mount`. The check was an unanchored substring search, and it matched this
repository's own comment explaining *why* the socket is deliberately absent.
The runtime measurement on the same container had correctly reported no socket.
Comment lines are now stripped before every static check.

---

## 2026-10-13 — Kubernetes, 6-node ARM64 cluster (Calico)

Deployed to a real cluster for the first time. This run found **three defects
that no amount of local review would have caught**, all of them in the shipped
manifests or entrypoint rather than in the container hardening.

### Getting to Running

| Step | Result |
|---|---|
| `kubectl apply -k deploy/k8s` | ✅ namespace, ServiceAccount, Service, 2×PVC, Deployment, 3×NetworkPolicy |
| Pod scheduled | ❌ → ✅ **`storageClassName: standard` hard-coded, cluster's default is `ceph-rbd`** |
| Container started | ❌ → ✅ **`PI_CAGE_PORT` clobbered by a Kubernetes service link** |
| Pod Ready | ❌ → ✅ **`tcpSocket` probes cannot reach a loopback-only listener** |
| Final | ✅ `1/1 Running`, Service endpoint `10.244.0.24:7681` |

**1. `storageClassName: standard`.** The PVCs sat `Pending` for ever, so the Pod
was never scheduled and reported `NODE <none>`. Fixed by omitting
`storageClassName` so the cluster default applies — hard-coding any class name is
the same trap. Note PVC `storageClassName` is immutable: fixing it required
deleting and recreating the (still unbound) claims.

**2. Service links collided with `PI_CAGE_PORT`.** The container crash-looped:

```
pi-cage: serving /workspace on 127.0.0.1:tcp://10.107.230.100:7681
ttyd: invalid value for port: tcp://10.107.230.100:7681
```

Kubernetes injects `<SERVICE>_PORT` for every Service in the namespace. The
manifest creates a Service named `pi-cage`, so the cluster set `PI_CAGE_PORT` —
the exact name the entrypoint uses for its listen port. **Guaranteed for anyone
deploying these manifests.** Fixed with `enableServiceLinks: false`, plus numeric
validation in `pi-server` so any future injection fails with a message that names
the cause instead of ttyd's useless one.

**3. `tcpSocket` probes versus a loopback listener.** ttyd was listening
(`Listening on port: 7681`, auth header / origin check / max-clients all applied)
but the Pod stayed `0/1 Ready` for ever. A `tcpSocket` probe is opened by the
kubelet against the **Pod IP**, and `serve` binds `127.0.0.1` on purpose — the
probe and the security posture are in direct conflict, so it could never succeed.
All three probes are now exec probes connecting to loopback from inside.

### Network boundary — `verify-network-boundary.sh`, exit code 0

| Section | Result |
|---|---|
| Preflight (11 cluster checks) | ✅ 11/11 |
| Internal + metadata, must be refused | ✅ `kubernetes.default.svc:443`, `192.168.137.101:22`, `169.254.169.254:80` all **DROPPED(timeout)** |
| Public, smoke test only | ✅ reachable (resolved into fake-ip space, as expected here) |
| DNS | ✅ cluster name → `10.96.0.1`; public name resolves |
| Ingress from an unlabelled Pod | ✅ **BLOCKED(timeout)** — an unlabelled Pod in `default` cannot reach the web terminal |

**The hard criterion is the denial direction and it holds.** Preflight confirmed
`public-egress` omits `198.18.0.0/15` and excludes all six required internal
ranges, that `default-deny` covers both directions, and that `proxy-ingress`
requires the `pi-cage-client=true` label.

**One false failure on the first run**, again in the checker: `proxy-ingress`
label matching expected the Go map rendering `map[pi-cage-client:true]` while
kubectl produced JSON `{"pi-cage-client":"true"}`. Third instance of the same
class — *a verifier that has never been run against a real system is just another
unverified claim.*

### Container, measured on the live Pod

| Check | Result |
|---|---|
| uid | ✅ `uid=10001(pi) gid=10001(pi)` |
| Read-only root filesystem | ✅ `touch /nope` → `Read-only file system` |
| Writable state | ✅ `/workspace` and `/home/pi` writable |
| Docker socket | ✅ absent — `/var/run/docker.sock: No such file or directory` |
| Host paths | ✅ none of `/host`, `/srv`, `/opt`, `/home` from the host in `/proc/mounts` |
| Pinned Pi version | ✅ `pi --version` → `0.99.2` |
| Running image | `arm-cluster-master:5000/pi-cage:20261013T060112Z` |

### `serve` composition, exercised directly

Ran the exact command ttyd forks, detached, and captured the pane:

```
▀▀█  v0.99.2
█▀ █ escape interrupt · ctrl+c/ctrl+d clear/exit · / commands · ! bash ·
/workspace
```

Process in the pane: `pi`. So `tmux` + `pi` compose correctly inside the
container.

**Which surfaced a fourth defect:**

```
fd not found. Downloading...
```

Pi's `find` tool shells out to `fd`, and when it is missing Pi **downloads a
binary at runtime** — an unpinned executable fetched on first use, in an image
whose entire premise is a pinned supply chain. Fixed by installing Debian's
`fd-find` (binary name `fdfind`, so a symlink provides `fd`) and adding `fd` to
the required-tools gate in `docker/assert-image.sh`, so a regression fails the
build rather than silently reintroducing the download.

---

### The `fd` fix, confirmed on a rebuilt image

Rebuilt as `arm-cluster-master:5000/pi-cage:20261013T161134Z` and rolled out.

| Check | Result |
|---|---|
| `fd` on PATH inside the Pod | ✅ `fdfind 8.6.0` |
| `pi` startup pane | ✅ `▀▀█ v0.99.2` — **no `fd not found. Downloading...` banner** |
| Boundary re-verified after the rebuild | ✅ `verify-network-boundary.sh` exit code **0** |

The pane also showed, for the first time, the next thing that is genuinely
untested:

```
 Warning: No models available. Use /login to log into a provider via OAuth or
 API key.
```

That is correct behaviour — no provider credentials have been configured. It
also means **no model call has ever been made from this image**, which is why
"behaviour under a real workload" stays on the list below.

### The boundary check now proves coverage, not just presence

The verifier used to confirm that six customary `except` entries were present.
On this cluster that passed -- but only because its Pod CIDR (`10.244.0.0/16`)
and Service CIDR (`10.96.0.0/12`) happen to fall inside `10/8`. On a cluster
using other ranges, the same green run would have meant nothing: a silent false
green, and the third time this project shipped a check that reported on itself.

It now reads this cluster's own addresses and tests each against the loaded
policy with real IPv4 containment:

| Check | Result |
|---|---|
| Five node Pod CIDRs (`10.244.0.0/24` ... `10.244.4.0/24`) | covered by `10/8` |
| `kubernetes` Service ClusterIP `10.96.0.1` (Service CIDR) | covered by `10/8` |
| Cluster-internal grants in `public-egress` | 2 of 2 allowed (the two DNS label variants) |
| Full run | exit code **0** |

**Negative-tested**, because a check that only ever passes proves nothing. With
`10/8` removed from a synthetic except list, this cluster's real Pod IP
(`10.244.0.7`) is correctly reported as **uncovered**; with it present,
correctly covered. So the check discriminates rather than passing vacuously.

`--suggest-excepts` prints a ready-to-paste block derived from the cluster, for
anyone whose Pod or Service ranges fall outside the shipped template.

Two portability defects were fixed alongside it, both of the same class as the
earlier hard-coded `storageClassName`:

- **`nodeSelector: kubernetes.io/arch: arm64`** in `core.yaml` was silently fatal
  on every other architecture -- `Pending`, with a message that reads like a
  capacity problem. Removed; single-arch builders add it back via a patch.
- **The cluster-internal-grant allowance was hard-coded to 1**, so adding the
  second DNS label variant broke the check. A hard-coded count in a verifier is
  the same trap as a hard-coded CIDR list.

Engine detection now covers Antrea, `aws-node` and `azure-cni-networkmonitor` as
well as Calico, Cilium and kube-router, and is overridable with
`PI_CAGE_POLICY_ENGINE`. The old list turned "unrecognised CNI" into "no
boundary", which is the wrong conclusion.

---

## 2026-10-14 — `linux/amd64`, Tencent Cloud VPS (2 vCPU / 1.9 GiB, mainland China)

Roadmap item 5. The amd64 image had never been built, which excluded every x86
user before anything else was considered.

This run took longer than it should have, and the reason is worth recording: the
build host's network blocks two inputs that had never been exercised, and both
failures looked like something other than what they were.

### Two blocked inputs, and what they cost

**1. `github.com` is unreachable from this host.** `git clone` times out after
134 s and a release-asset download returns zero bytes after 60 s — while
`codeload.github.com` and the registry mirror answer normally. That kills the
`ttyd` fetch and nothing else.

Rather than work around it by hand, the download was made relocatable:
`TTYD_BASE_URL` / `--ttyd-base-url`. **The SHA-256 check runs whatever the
source**, so moving the download cannot weaken the pin — the pin is the digest,
not the URL. That was tested, not asserted: the amd64 binary was extracted from
the `tsl0922/ttyd` image, a different transport entirely, and its hash matched the
value already pinned in the Dockerfile —

```
8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
1362040 bytes, ELF, byte-identical to the release asset
```

**2. `deb.debian.org` stalls.** The in-container `apt-get` ran for **19 minutes**
with one open connection and a **load average of 0.18** — no CPU use, which is the
signature of a network stall rather than work. `mirrors.cloud.tencent.com`
answered both the `debian` and `debian-security` suites instantly. Adding
`APT_MIRROR` / `--apt-mirror` cut the build to about four minutes.

Both are the same shape as the `NPM_REGISTRY` and `PIP_INDEX_URL` overrides this
ecosystem already carries. Three build inputs can be blocked by a network: the
base image registry, the `ttyd` asset, and the apt mirror. All three are now
overridable, and none of them weakens a pin.

**A third bug surfaced while testing the first two.** `--dry-run` had never
worked: `build_args` was assigned only inside the `DRY_RUN=0` branch, so
`"${build_args[@]}"` aborted under `set -u` with "unbound variable" — and it also
required Docker to be installed, which defeats the point of a flag documented as
"print the plan, touch nothing". Both fixed, with a regression check.

### Build

| Check | Result |
|---|---|
| Base image architecture asserted | ✅ `amd64` |
| Base image pinned to digest | ✅ `node@sha256:d6aa754f16b3197301…` (same manifest-list digest as the arm64 build) |
| `ttyd` SHA-256 verified from a non-GitHub source | ✅ |
| Pi installed at the exact pinned version | ✅ `@earendil-works/pi-coding-agent@0.99.2` |
| Build-time gates in `assert-image.sh` | ✅ |
| Image | `pi-cage:20261014T112957Z`, `linux/amd64`, 1.11 GB, `user=10001:10001` |

### `./verify-hardening.sh` on amd64 — 22/22, exit code 0

| Section | Result |
|---|---|
| A. Image properties | ✅ 3/3 |
| B. Reference run configuration, static | ✅ 9/9 |
| C. Runtime measurement | ✅ 6/6 — read-only rootfs, all capabilities dropped, no-new-privileges, no Docker socket, no host paths, no host Docker data directory |
| D. Refusals and absences | ✅ 4/4 |

The same checks that pass on ARM64 pass on amd64, from an image built on a
different host with different mirrors. Multi-arch is real, not claimed.

**Not covered by this run:** the `--multiarch` buildx path itself is still
unexercised — this was two single-arch builds on two machines, not one
manifest-list build. See the table below.

### Host hygiene

The VPS runs `frps` and listens on `:7000`; it is an entry point for other
infrastructure. It was checked before and after every step and was never touched.
Docker was installed for this build, and one pinned `ttyd` asset was staged over
the Docker bridge on `172.17.0.1` — not on a public interface — and the helper was
stopped afterwards.

---

## Not yet verified

| Claim | Status |
|---|---|
| **Any model call** | **Never made.** The TUI starts and reports "No models available"; no provider credentials are configured and no prompt has been run in this image. |
| Multi-arch buildx (`./build.sh --multiarch`) | **Never run.** arm64 and amd64 both build and pass, but as two separate single-arch builds on two hosts — not one manifest-list build. |
| Behaviour under a real workload | **Never run.** No agent has been given a task; only the startup path was exercised. |
| Behaviour under attack | **Never attempted.** |
| `serve` through a real authenticating proxy, in a browser | **Never run.** The ttyd/tmux/pi composition was verified directly, but no reverse proxy has injected `X-Auth-Request-Email`, and no WebSocket upgrade has crossed the tunnel. |
| `run` / `json` modes | **Never run.** Only `serve` was exercised. |

---

## How to add an entry

```
## <date> — <platform>, <whose host>

Built with:  <command>
Image:       <tag or digest>

<what you ran>            <what it reported>
...

### Deviations from the expectation table
<anything that surprised you, and why>
```

Negative results are more valuable than positive ones. If something did not
behave as the README says, record it here whether or not you fixed it.
