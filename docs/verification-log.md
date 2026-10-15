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

## 2026-10-14 — Published to GHCR, and the reference Pod was unreachable

Two things happened in this stretch: the image was published, and then trying to
reach it found that **the reference Kubernetes manifest produced a Pod nothing
could connect to.**

### Multi-arch manifest list

`ghcr.io/zmhhaha/pi-cage`, index `sha256:897709bdb3f6a123fd3acd5da3f02f9491a217f1c0b67ab577c61dd965b868b2`,
tagged `:latest` and `:20261014`:

| Platform | Manifest | Built on |
|---|---|---|
| `linux/amd64` | `sha256:cbd3c1960ddc76d835d32afd22b2cb70be6b5ef071c2892aa0cf3cdd53ff6cd9` | the x86 VPS |
| `linux/arm64/v8` | `sha256:b0905fa77029ad7520e6433c1462298435eb318350364b401752e11aad086e19` | `arm-cluster-master` |

Pulled back from GHCR on both hosts: the same index digest resolved to
`cbd3c1960ddc` on amd64 and `6948c9a2fe82` on arm64. That is a multi-arch image
working, not a claim about one.

The two single-arch images came from **different hosts, different commits and
different mirror sets**, so equivalence was measured instead of assumed:

| | arm64 | amd64 |
|---|---|---|
| Packages | 127 | 127 — **identical names and versions** |
| node | v24.21.0 | v24.21.0 |
| ttyd | 1.7.7-40e79c7 | 1.7.7-40e79c7 |
| `dist/bundle/cli.js` | `e79626f2…` | `e79626f2…` (**byte-identical**) |
| `/usr/local/bin/ttyd` | `b38acadd…` | `8a217c96…` — the per-architecture pin |

Only the `ttyd` binary legitimately differs.

**Public, verified by the only test that distinguishes it.** A private package and
a public one look identical to a client that holds credentials, so the check was
made from a host with none:

| Probe | Result |
|---|---|
| Anonymous token (`/token?scope=repository:zmhhaha/pi-cage:pull`) | issued |
| Anonymous `tags/list` | `200` — `arm64`, `amd64`, `latest`, `20261014` |
| Anonymous `manifests/latest` | `200` |
| `docker logout ghcr.io`, then `docker pull ghcr.io/zmhhaha/pi-cage:latest` | succeeded, resolved index `sha256:897709bd…` |

So a Kubernetes node needs no `imagePullSecret`. The package is also linked to the
repository, so its page shows the project instead of an orphan image.

**Not verified here:** the linkage itself. GitHub's package API returns `401
Requires authentication` even for a public package, so it was confirmed by
clicking rather than by a probe — the one claim in this section that rests on
observation rather than measurement.

### The Pod could not be reached

`core.yaml` declared `containerPort: 7681`, defined a Service on 7681, set
`PI_CAGE_AUTH_HEADER`, and carried a comment about the Service being reachable only
through the labelled ingress source — but never set `PI_CAGE_BIND`. So `serve` used
its default and listened on **`127.0.0.1` only**, and a Service DNATs to the Pod IP.

Measured:

| Probe | Result |
|---|---|
| `/proc/net/tcp` in the live Pod | `0100007F:1E01` = `127.0.0.1:7681` |
| From inside the Pod | reachable — ttyd answered `407 Proxy Auth Required` |
| `docker run -p 127.0.0.1:17681:7681 … serve`, then curl | `Connection reset by peer` |
| From a labelled Pod in another namespace, after the fix | `nc` exit 0, `HTTP/1.1 407` |

**Fix:** set `PI_CAGE_BIND=0.0.0.0` and `PI_CAGE_ALLOW_PUBLIC=1` in `core.yaml`. The
boundary for that Deployment is not the bind address; it is the two layers that
already existed and are now stated next to those variables — the `proxy-ingress`
NetworkPolicy admitting only sources labelled `pi-cage-client: "true"`, and ttyd
requiring the auth header.

### Correction: an intermediate conclusion in this investigation was wrong

While diagnosing the above, a labelled test Pod in the `pi-cage` namespace could
not reach the Pod IP, and that was taken as confirmation that the bind address was
the cause. **It proved nothing.** `default-deny` in that namespace selects all Pods
with `policyTypes: [Ingress, Egress]`, so the test Pod's own **egress** was denied
and it could never have connected regardless of what the target was bound to.

Re-run from a labelled Pod in the `default` namespace — where no policy restricts
egress — the connection succeeds and ttyd answers `407`. That is the version
recorded above.

The loopback finding stands on its own evidence, which involves no policy at all:
`/proc/net/tcp` inside the container, and `docker run -p` failing with
`Connection reset by peer`.

**The general lesson, and it is the same one as the survey correction in
[prior-art.md](prior-art.md): a probe that fails tells you nothing until you have
established that it was capable of succeeding.** The first in-cluster test here had
a blocked egress path and looked exactly like a blocked ingress path.

### Coverage this exposed as missing

Every check before this one inspected the container's **properties** — uid, caps,
read-only rootfs, mounts, refusals — and none tried to **connect to it**. That is
why a manifest that could never serve a request passed every gate. Reachability is
now part of what gets checked.

---

## 2026-10-14 — What the auth header actually enforces

Written up as [auth.md](auth.md). One measurement is worth stating on its own,
because it changes how the whole deployment should be read:

| Request to a running `serve`, `PI_CAGE_AUTH_HEADER=X-Auth-Request-Email` | Result |
|---|---|
| no header | `407` |
| `someone@example.com` | `200` |
| `x` | `200` |
| empty value | `407` |
| `$(id)` | `200` |

**`ttyd` checks presence and non-emptiness. It does not check the value and does
not verify any signature.** The header is a bearer token. Everything that actually
protects a deployment lives outside the container: the network policy that decides
who can reach the port, and the single proxy that is supposed to set the header.

The failure mode this rules out is the comfortable one — that a valid-looking
`X-Auth-Request-Email` means the request came from an authenticated user. It does
not mean that. It means whoever sent it could open a TCP connection.

### Also established, from a working production configuration

- `set_xauthrequest = true` is required for `oauth2-proxy` to emit the header at
  all; a correct OIDC login still ends in `407` without it.
- `proxy_websockets = true` is required or the terminal never connects.
- `cookie_secret` must be exactly 16, 24 or 32 bytes, and an email allow-list is
  mandatory. Both were reproduced as startup failures rather than taken on faith.
- Read off the live policies: `public-egress` selects `role: cage` only, so an
  OIDC sidecar needs that label or it cannot reach the issuer; and `proxy-ingress`
  admits **only port 7681**, so a sidecar listening on 4180 needs a policy change.

One of those was observed rather than inferred: a sidecar without `role: cage`
reached `Performing OIDC Discovery...` and never progressed, because
`default-deny` denies egress to every pod in the namespace and only `role: cage`
gets a public-egress rule.

### Not established

The sidecar manifest in `auth.md` has never been applied, and no login has been
completed in a browser. The OIDC round trip and the WebSocket upgrade through a
real proxy remain unverified, and `auth.md` says so in its own table.

---

## 2026-10-15 — What `run` and `json` do when they fail

Both modes had never been executed. They could not be exercised on their success
path without a provider credential, but **the failure path is half the contract**,
and it needs nothing:

| | exit | stdout | stderr |
|---|---|---|---|
| `run "reply with the single word ok"` | `1` | **0 bytes** | `No API key found for the selected model.` |
| `json "…"` | `1` | **1 line, valid JSON** | the same |
| an unknown mode | `1` | nothing | the usage block |

Run against `ghcr.io/zmhhaha/pi-cage:latest` with no API-key environment variable
present at all, capturing stdout and stderr separately.

**Three facts, none previously established:**

- **A failed `run` leaves stdout empty.** The mode exists so the agent's final
  text can be piped; a diagnostic leaking into stdout would corrupt every
  consumer. `pi-server` routes both `log()` and `die()` to stderr by construction,
  and this confirms the arrangement holds on the failure path rather than only
  being intended.
- **`json` emits valid JSONL, and the first record survives the failure:**
  `{"type":"session","version":3,"id":"…","timestamp":"…","cwd":"/workspace"}`.
  A consumer gets a session line before the error instead of a broken stream.
- **`run` and `json` dispatch correctly at all.** They reach the model call and
  fail there. That is a different claim from "the modes are wired up", and it is
  the one the README was making on the strength of upstream's documentation.

**Also settled:** an unknown mode exits **1**, not 2. `pi-server` sends every
fatal path through `die()`, so all of its failures share a code; the `2` in
`build.sh` is that script's own convention for a usage error. Not a discrepancy,
and worth writing down because it looked like one.

**Superseded the same day** — see the next section. A credential became available
and the success path was exercised.

---

## 2026-10-15 — The first real model calls, and the boundary holding under a real task

Run in the `pi` namespace deployment on the 6-node cluster, with
`DEEPSEEK_API_KEY` delivered from Vault through an ExternalSecret. **These are the
first model calls this image has ever made**, and the first time it has been given
work to do rather than merely started.

### `run` — success path

```
pi-server run "reply with the single word ok"
  exit code : 0
  stdout    : "ok"   (3 bytes)
  stderr    :        (0 bytes)
```

Exactly the acceptance criterion roadmap item 3 was written against. stdout
carries the agent's text and nothing else; a diagnostic leaking there would
corrupt any pipeline built on this mode.

### `json` — success path

```
  exit code : 0
  stdout    : 15 lines, 20,570 bytes — 15 valid JSON, 0 invalid
  stderr    : 0 bytes
```

Event types, in order:

```
session → agent_start → turn_start
  → (message_start → message_update → message_end) × 3
  → turn_end → agent_end → agent_settled
```

A complete, well-formed JSONL stream ending in `agent_settled`. Parseable line by
line, which is the whole contract of this mode.

### A real task, and the boundary holding

Nothing here had ever been given work to do. The prompt asked for two things: write
a file inside the workspace, and attempt to write one outside it.

```
  WORKSPACE=pi-cage ran here
  OUTSIDE=EROFS: read-only file system, open '/nope.txt'
```

**The agent hit the read-only root filesystem itself and reported the real error.**
That is the deployment's central claim happening rather than being asserted: given
full tool access, the agent physically cannot write outside its workspace.

**Checked independently of the model's own account**, because a self-report is not
evidence:

| Probe from outside the container | Result |
|---|---|
| `/workspace/proof.txt` exists | yes, contents exactly `pi-cage ran here` |
| `/nope.txt` exists | no |
| root filesystem writable | no — `touch` fails |

### What else this incidentally confirmed

- **Egress works through the namespace policy.** The model API was reachable over
  public TCP 443 under `web-egress` while every internal range stayed denied. A
  policy mistake here would have shown up as a failed call, not a silent one.
- **The workspace PVC is writable by uid 10001.** The `fsGroup`/`fsGroupChangePolicy`
  arrangement in `core.yaml` does what it is there for.
- **The read-only root plus explicit tmpfs mounts are sufficient.** No mode needed
  a writable path outside `/workspace`, `/home/pi`, `/tmp` or `/run`.

### Still not verified

The **web terminal has never been opened in a browser**. The `pi-cage` container
ran, but `oauth2-proxy` sat in `CreateContainerConfigError` for want of
`secret/pi/oidc`, so nothing crossed the proxy: no login round trip, no WebSocket
upgrade, no TUI in a browser. The modes exercised here are the two that do not go
through it.

---

---

## 2026-10-15 — The deployed auth chain, and one open question about `/ws`

Measured in the `panghu_chat/pi` deployment: `pi-cage` and `oauth2-proxy` as
sidecars, `pi-oidc` delivered from Vault, Pod `2/2`.

### The test that mattered, and passed

`oauth2-proxy` sets `X-Auth-Request-Email` on what it forwards upstream. If it also
forwarded a header the *client* supplied, then anything able to reach port 4180
would bypass Casdoor by sending one line — and 4180 is what the public tunnel
fronts. So it was worth trying to forge it:

| Request to the proxy | Result |
|---|---|
| no header | `302` to the IdP |
| forged `X-Auth-Request-Email` | `302` to the IdP |
| forged `X-Auth-Request-User` | `302` to the IdP |
| forged `X-Forwarded-User` | `302` to the IdP |
| forged `X-Forwarded-Email` | `302` to the IdP |
| both forged at once | `302` to the IdP |

**`oauth2-proxy` strips client-supplied identity headers.** The bypass does not
exist. An unauthenticated `/ws` through the proxy also returns `302`, so the
terminal endpoint is behind the session like everything else.

### One open question: the auth header on `/ws`

Probing `ttyd` directly on its loopback port, under
`PI_CAGE_AUTH_HEADER=X-Auth-Request-Email`:

| Request | Result |
|---|---|
| `GET /` without the header | **`407 Proxy Auth Required`** |
| `GET /` with the header | `200 OK`, 729,693 bytes |
| `GET /ws` (Upgrade: websocket) without the header | **`101 Switching Protocols`**, 0 body bytes |
| `GET /ws` with the header | **`101 Switching Protocols`**, 2 body bytes: `89 00` — a WebSocket ping |

**The header check produces `407` on the HTTP path and `101` on the WebSocket
path.** With the header, ttyd completes the handshake and starts pinging; without
it, the upgrade is still granted and nothing follows within the observation
window.

**What this does not establish, and is not claimed:** that the unauthenticated
upgrade yields a usable terminal. Attempts to drive ttyd's protocol far enough to
see a command echoed back failed **in both cases**, including the authenticated
one, so they could not distinguish a live session from a dead socket. The honest
statement is that the two paths do not behave the same, and the consequence of
that difference is **undetermined**.

**Why it is worth recording rather than dropping.** This project's design states
that the header is one of two layers protecting the terminal, and that claim is
now known to hold on the HTTP path and to be unverified on the WebSocket path.
`deploy/k8s/core.yaml` binds `0.0.0.0` and relies on `proxy-ingress` plus the
header; if the header does not cover `/ws`, that manifest has one layer there
rather than two. In the `panghu_chat/pi` deployment it is narrower still — ttyd is
loopback-only and `oauth2-proxy` gates `/ws` at its own layer — so nothing outside
the Pod reaches it either way. But the shipped manifest makes the stronger claim
and should not, until this is settled.

**Follow-up:** determine whether ttyd's `--auth-header` is meant to cover the
WebSocket upgrade, ideally against ttyd's own source at the pinned version, and
either document the gap in [THREAT-MODEL.md](../THREAT-MODEL.md) or stop relying
on the header for that path.

### Also confirmed

The unauthenticated redirect carries the real client id and
`redirect_uri=https://pi.panghuer.top/oauth2/callback`, so the Casdoor application
is wired correctly. What remains untested is a completed login in a browser and a
WebSocket upgrade crossing the proxy — those need a human with a browser session.
## Not yet verified

| Claim | Status |
|---|---|
| **Any model call** | **Done, 2026-10-15.** Both `run` and `json` succeed against `DEEPSEEK_API_KEY` delivered from Vault, and a real file-writing task with a boundary probe completed. See the section above. |
| **`docker-compose.yml` works** | **It does not.** It publishes `127.0.0.1:7681:7681` while the container binds loopback — the same contradiction as the Kubernetes manifest, and the same fix does not apply cleanly. Options and their costs are in [roadmap.md](roadmap.md). |
| A completed login in a browser, and a TUI on screen | **Never done.** The proxy is up, forwards to the real Casdoor with the right `redirect_uri`, strips forged identity headers, and gates `/ws` — all measured. No human has completed the round trip, and no WebSocket upgrade has crossed the proxy. |
| The auth recipe in [auth.md](auth.md) | **Mostly.** The sidecar manifest is **applied and running at 2/2**; the header behaviour, the header-stripping and the redirect are measured. A completed browser login is not. |
| **Whether the auth header covers the WebSocket** | **Open, 2026-10-15.** `GET /` without the header gives `407`; `GET /ws` without it gives `101`. Whether the unauthenticated upgrade becomes a usable session is **undetermined** — see the section above. `deploy/k8s/core.yaml` relies on that header as one of two layers. |
| Multi-arch buildx (`./build.sh --multiarch`) | **Never run.** The published index was assembled with `docker manifest create` from two single-arch builds, not by a buildx manifest-list build. The result is equivalent; the code path is untested. |
| Behaviour under a real workload | **Done, 2026-10-15.** An agent was given a task using its file tools; it wrote where it should and was refused where it should not. See the section above. |
| Behaviour under attack | **Never attempted.** An adversarial prompt — one instructing the agent to exfiltrate, or to look for a way out of the boundary — has never been tried. The EROFS refusal above was an incidental consequence of a task, not an adversarial test. |
| **The release workflow has run** | **Never.** `.github/workflows/release.yml` has been written and read, not executed — no tag has been pushed since it existed. |
| **A tagged release exists** | **None.** The SBOMs are committed rather than attached to a release, which is the weaker form of the acceptance criterion. |
| **The published images carry OCI labels** | **They do not.** `Config.Labels` is `null` on both. The Dockerfile now sets them so the next build has them; these two images do not, and were deliberately not back-filled. |

---

## 2026-10-14 — SBOMs, and what they do not cover

Generated with syft for both published architectures, committed under
[`sbom/`](../sbom/README.md).

**They were generated from local image archives, not from the registry.** Pointing
syft at `registry:ghcr.io/...` failed on both hosts with `connection reset by peer`
against GitHub's CDN — the same mainland-China network boundary that blocked
`github.com` during the amd64 build. A document that cannot be regenerated where it
was made is not worth much, and `docker save` plus
`syft docker-archive:` needs no network at all.

**What they settled.** Comparing the two documents by `name@version`:

| | arm64 | amd64 |
|---|---|---|
| Packages | 438 | 438 |
| Unique `name@version` | 425 | 425 |
| Present in only one | **0** | **0** |

This is a stronger claim than the `dpkg-query` comparison it supersedes, because it
comes from the published artifacts and includes the npm tree and the Node runtime,
not just the OS packages.

**What they exposed.** The SBOM does **not** cover `ttyd`. It is a statically
linked C binary with libwebsockets inside, and syft has no cataloguer for it: it
appears in the file list as `usr/local/bin/ttyd` with no version and no
dependencies, and `libwebsockets` does not appear at all. `ttyd` is one of the
three pinned inputs to this image, so the SBOM covers two of them and the
authoritative record for the third remains the SHA-256 in the Dockerfile.

That is the useful part. An SBOM that is assumed to cover everything is worse than
one whose boundary is written down.

**Added at the same time:** `PROVENANCE=1` support in `build.sh`
(`--provenance=mode=max --sbom=true`) and
[`.github/workflows/release.yml`](../.github/workflows/release.yml), which does the
whole release in one manifest-list build. **The workflow has not run** — see the
table above.

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
