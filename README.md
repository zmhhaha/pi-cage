# pi-cage

**An isolation-first container for the [Pi coding agent](https://github.com/earendil-works/pi).**

Pi has no built-in sandbox — by design, its `bash` tool runs commands with the permissions of whatever account started it. `pi-cage` takes the position that **the container is the boundary**: no Docker socket, no host paths, no `hostexec`, no cluster credentials. The agent gets a workspace and a network policy, and nothing else.

> ### ⚠️ Status: pre-alpha, container verified on ARM64
>
> **`linux/arm64` builds end to end (2026-10-13), and [`./verify-hardening.sh`](verify-hardening.sh) passes every check against the built image.** No image is published anywhere yet.
>
> **Verified so far:** the ARM64 build completes; `ttyd` is downloaded and SHA-256 verified; Pi installs from npm; the build-time gates in [`docker/assert-image.sh`](docker/assert-image.sh) pass; and the container-level hardening claims hold on a real container — read-only root filesystem, all capabilities dropped, no-new-privileges, **no Docker socket, no host paths**, and all four fail-closed refusals.
>
> **Not yet verified:** the Kubernetes network boundary ([`verify-network-boundary.sh`](verify-network-boundary.sh)) has not been run against a cluster, and this container has never run a real workload or been attacked. [THREAT-MODEL.md](THREAT-MODEL.md) records what is not defended at all. See [docs/verification-log.md](docs/verification-log.md) for what was checked, when, and on what.


---

## Quick start

```bash
git clone https://github.com/zmhhaha/pi-cage.git
cd pi-cage
./build.sh                       # local single-arch image
mkdir -p workspace && sudo chown 10001:10001 workspace   # see the bind-mount note
docker compose run --rm pi-cage run "summarise this repository"
```

`docker-compose.yml` has no `build:` key on purpose — `docker compose build` would bypass every digest pin and architecture assertion in `build.sh`. Build first, then compose consumes the image.

Interactive session over a web terminal:

```bash
PI_CAGE_AUTH_HEADER= docker compose up -d
# http://127.0.0.1:7681
```

`PI_CAGE_AUTH_HEADER=` disables the proxy-supplied auth header, which is only acceptable because Compose binds to `127.0.0.1`. See [Serving it to anyone else](#serving-it-to-anyone-else).

Kubernetes:

```bash
kubectl apply -k deploy/k8s
```

> ⚠️ **No image is published.** `deploy/k8s/core.yaml` references `ghcr.io/zmhhaha/pi-cage:latest`, which does not exist, so applying as-is leaves the Pod in `ImagePullBackOff` — the Deployment and the three NetworkPolicies are created, and nothing runs. Point [`deploy/k8s/kustomization.yaml`](deploy/k8s/kustomization.yaml) at an image your nodes can pull first; the three cases and their exact commands are in [deploy/k8s/README.md](deploy/k8s/README.md).

---

## Why this exists

The Pi ecosystem has plenty of good ways to run an agent. `pi-cage` does not try to
beat them — it covers the one layer they leave open: **a cluster with a network
boundary.**

The closest neighbours are [`pi-less-yolo`](https://github.com/cjermain/pi-less-yolo)
(isolated local Docker, 165★) and [`pi-dispatch`](https://github.com/edgehero/pi-dispatch)
(unattended jobs with budgets, 181★). Both are good, both are further along than this
project on their own axes, and neither targets Kubernetes or ships an egress policy.

| | [`pi-less-yolo`](https://github.com/cjermain/pi-less-yolo) (165★) | [`pi-dispatch`](https://github.com/edgehero/pi-dispatch) (181★) | **pi-cage** |
|---|---|---|---|
| Shape | Local Docker wrapper (`mise run pi`) | Self-hosted job service | **Long-lived container in a cluster** |
| Interactive session | ✓ that is the point | ✗ jobs only | **✓ `serve`** |
| Job queue, spend caps | ✗ | **✓✓ far ahead here** | ✗ |
| Drops all capabilities, no-new-privileges | ✓ | ✓ | ✓ |
| Mounts your project directory | ✓ read-write, by design | read-only instructions | **nothing from the host** |
| **Egress network boundary** | ✗ | ✗ | **✓ verified on a real cluster** |
| **Kubernetes** | ✗ | ✗ | **✓ manifests included** |
| One-command start | ✓ | ✓ | ✗ **see [docs/roadmap.md](docs/roadmap.md)** |

`pi-web`'s Docker containers take a different tack on purpose — mounting
`/var/run/docker.sock`, *"root-equivalent on the Docker host"* — because their value
is running the agent where your real code and credentials already are. That is a
defensible design; it is also what makes a Pod impossible, since the installer fails
closed without a rootful local socket.

**Use `pi-less-yolo` on your laptop, `pi-dispatch` for unattended jobs, and
`pi-cage` when the agent has to live in a cluster you would not hand a shell to.**

The full map, by layer, with the projects this project has learned from, is in
[docs/prior-art.md](docs/prior-art.md).


---

## What it is not

- **Not a web UI.** No chat interface is written here. `serve` exposes a terminal; if you want a rich UI, run [`agegr/pi-web`](https://github.com/agegr/pi-web) (7,315★, `npx @agegr/pi-web`) or [`jmfederico/pi-web`](https://github.com/jmfederico/pi-web) inside an image you build — see [docs/prior-art.md](docs/prior-art.md).
- **Not multi-tenant.** One container, one user, one agent. There is no account system and none is planned.
- **Not a host-development tool.** If you need the agent to touch host paths, use [`pi-less-yolo`](https://github.com/cjermain/pi-less-yolo) — it does that deliberately and well.
- **Not a job queue or a budget system.** [`pi-dispatch`](https://github.com/edgehero/pi-dispatch) covers that axis far better than this project plans to.
- **Not a sandbox for hostile code you deliberately run.** It is a container boundary, with all the usual caveats of one.

---

## Modes

| Command | What it does | Reachable over the network |
|---|---|---|
| `pi-server serve` | Persistent `tmux` session running `pi`, exposed through `ttyd` | Only via the port you bind |
| `pi-server run "<prompt>"` | One-shot. Final assistant text on stdout, non-zero exit on failure | No |
| `pi-server json "<prompt>"` | One-shot. JSONL event stream on stdout | No |
| `pi ...` | The raw CLI, for anything else | No |

`serve` binds `127.0.0.1` unless you explicitly opt out, and it refuses to start with authentication disabled on a public bind. This is deliberate fail-closed behaviour, not a bug.

---

## Hardening

**Two kinds of claim, and the difference matters.** Some properties are baked into the image; the rest are applied by the run configuration. A bare `docker run` has none of the second kind, so checking them there says nothing about the image.

```bash
./verify-hardening.sh                    # checks both, and refuses to guess
```

**Baked into the image** — an operator cannot turn these off:

```bash
docker image inspect pi-cage:latest --format '{{.Config.User}}'   # 10001:10001
```

**Applied by the run configuration** — here, `docker-compose.yml`; in a cluster, `deploy/k8s/core.yaml`:

```bash
docker inspect <container> --format '{{json .HostConfig.ReadonlyRootfs}}'  # true
docker inspect <container> --format '{{json .HostConfig.CapDrop}}'         # ["ALL"]
docker inspect <container> --format '{{json .HostConfig.SecurityOpt}}'     # no-new-privileges:true
docker inspect <container> --format '{{range .Mounts}}{{.Source}} {{end}}' # no docker.sock, no host paths
```

| Property | Kind | Where |
|---|---|---|
| Non-root (`10001:10001`) | image **and** run config | `USER` in the Dockerfile; `user:` / `runAsUser` |
| No Docker client in the image | image | nothing installs one |
| Read-only root filesystem | run config | `read_only: true`; `/tmp` and `/run` are `noexec,nosuid` tmpfs |
| No capabilities | run config | `cap_drop: [ALL]` |
| No privilege escalation | run config | `no-new-privileges:true`, seccomp `RuntimeDefault` |
| No host access | run config | No Docker socket, no host path mounts, no `hostexec` |
| Pinned supply chain | image | Base image pinned by digest, Pi to an exact version, `ttyd` to a SHA-256 — all recorded in `rendered/` |
| Fail-closed defaults | image | `serve` refuses a non-loopback bind, and refuses a public bind with auth disabled |
| Multi-arch | image | `linux/amd64` and `linux/arm64` (ARM is the primary target — see below) |


### ARM64 is a first-class target, not an afterthought

`pi-web` publishes no multi-arch image and its Docker manual never mentions `arm64`. `pi-cage` is developed on an ARM64 Kubernetes cluster, so `linux/arm64` is verified on real hardware before release. If you run a Raspberry Pi, an Orange Pi, an Ampere box or a Graviton instance, this is the gap you have been hitting.

---

## Serving it to anyone else

`pi-cage` does not ship an authenticating proxy. That is a deliberate scope choice — bundling an OIDC stack would make this an identity product, and there are better ones.

`serve` trusts a header injected by whatever sits in front of it (`X-Auth-Request-Email` by default). Put a real proxy there. The Kubernetes manifests pair with any ingress that sets that header; with Compose, put Caddy, Traefik, `oauth2-proxy` or Tailscale in front.

**Never port-forward this container's port directly to the internet.** The agent executes shell commands with the container's privileges and reads any credentials in it. A terminal on the open internet is a shell on the open internet.

---

## Building

```bash
./build.sh                    # current architecture
./build.sh --multiarch        # buildx, pushes linux/amd64 + linux/arm64
./build.sh --dry-run          # print what it would do
```

`build.sh` pulls the base image, asserts its architecture, resolves it to a digest, and builds exclusively from that digest. It fails the build if:

- the base image is not the expected architecture,
- Node is below the version Pi requires,
- `ttyd` is missing any flag `serve` relies on,
- Pi is not pinned to an exact version.

The last two matter: a `ttyd` without `--auth-header` or `--check-origin` would silently drop an access control, and an unpinned Pi would let a rebuild change the CLI contract underneath you.

### Where `ttyd` comes from (and why not `apt`)

The first real build, on 2026-10-13, failed at step 5:

```
Package ttyd is not available, but is referred to by another package.
E: Package 'ttyd' has no installation candidate
```

**Debian bookworm has no `ttyd` package.** It only appears in later Debian suites. So the Dockerfile installs the upstream static release from [`tsl0922/ttyd`](https://github.com/tsl0922/ttyd) instead — **pinned by SHA-256 digest**, not by version tag, and verified with `sha256sum -c` during the build.

The digests live as `ARG`s next to `TTYD_VERSION` in the Dockerfile. Fetching the release's own `SHA256SUMS` from the same origin would only catch a corrupted download, never a tampered one — the transcribed digests are the actual pin. **Update `TTYD_VERSION` and both architecture digests as a set.**

Only `linux/amd64` and `linux/arm64` are mapped. Any other architecture fails the build with an explicit message rather than silently producing an image without `serve` mode.

#### If `github.com` is unreachable where you build

Measured on a Tencent Cloud VPS in mainland China: `github.com` times out entirely — `git clone` and release-asset downloads both — while `codeload.github.com` and the registry mirror work fine. That kills this build step and nothing else.

Point the download somewhere else:

```bash
# a mirror or internal artifact store, laid out as <base>/<version>/<asset>
./build.sh --ttyd-base-url https://mirror.example.com/ttyd

# or a local directory, which is what the amd64 build in
# docs/verification-log.md used
docker build --build-arg TTYD_BASE_URL=file:///srv/ttyd-assets .
```

**The SHA-256 check runs whatever the source.** Changing the URL cannot weaken the pin, because the pin is the digest and not the location — that was tested by extracting the binary from the `tsl0922/ttyd` image, fetching it from a different transport entirely, and confirming the hash matched.

That image is a viable alternative source in its own right: `tsl0922/ttyd:1.7.7` is multi-arch, and its `/usr/bin/ttyd` is byte-identical to the release asset. See [docs/roadmap.md](docs/roadmap.md).

#### If `deb.debian.org` is slow where you build

The same VPS that cannot reach `github.com` also **stalled for 19 minutes** on the
in-container `apt-get` step — one open connection, load average 0.18 — while
`mirrors.cloud.tencent.com` answered both suites instantly.

```bash
./build.sh --apt-mirror http://mirrors.cloud.tencent.com
```

The mirror must serve the `debian` **and** `debian-security` suites. Empty keeps
the base image's own sources, which is the default.

**This is the pattern for any future finding:** the build stops, the reason is written down here, and the fix is pinned rather than floated.

---

## Verifying it

Two scripts, two different claims. Run both before trusting a deployment.

### The container itself

```bash
./verify-hardening.sh pi-cage:latest
```

Separates **image** properties (baked in, an operator cannot turn them off) from **run-configuration** properties (applied by `docker-compose.yml` or the Kubernetes manifests). It measures the second kind on a container started with the reference flags, checks statically that the reference file still declares them, and confirms the fail-closed refusals actually refuse.

### The network boundary (Kubernetes only)

```bash
bash verify-network-boundary.sh --explain    # print the expectation table; touches nothing
bash verify-network-boundary.sh              # end-to-end; exit 0 is a pass
bash verify-network-boundary.sh --no-outsider  # skip section 5, which creates a Pod
```

It probes **from the real container**, not from a throwaway probe Pod, and reads the **cluster's** NetworkPolicies rather than the repository's copy — "committed" is not "loaded".

**The reading rule that matters: "must be refused" is the hard criterion; "must be reachable" is only a smoke test.** This network's router runs a transparent proxy, so *any* public address:port answers `CONNECTED`, including unroutable test ranges. Reachability therefore proves only that the packet left the container. A dropped packet never leaves the node, so the proxy cannot fake it — the denial direction is the real evidence.

Preflight refuses to produce a verdict at all if the cluster's policy no longer matches this script's expectation table, so a green run can't be stale. It also guards the single most expensive mistake available here: `198.18.0.0/15` in the egress `except` list. That range looks like harmless RFC 2544 benchmark space, but this network's fake-ip DNS resolves **every** external name into it — one line, and the entire public internet is excluded, model API included.

> **It does not cover plain Docker.** Compose has no egress control, so on a single Docker host the network boundary is whatever your firewall says. `pi-cage` does not provide one there. A green run of `verify-network-boundary.sh` says nothing about a Compose deployment.

---

## Documents

| File | Contents |
|---|---|
| [THREAT-MODEL.md](THREAT-MODEL.md) | Assets, adversaries, what is and is **not** defended. Read this before exposing anything. |
| [SECURITY.md](SECURITY.md) | How to report a vulnerability. |
| [docs/prior-art.md](docs/prior-art.md) | The landscape by layer, what `pi-cage` claims and does not, and what to borrow from whom. |
| [verify-hardening.sh](verify-hardening.sh) | Container-level checks: image vs run configuration, plus the refusals. |
| [verify-network-boundary.sh](verify-network-boundary.sh) | Kubernetes boundary checks, probed from inside the real container. |
| [docs/verification-log.md](docs/verification-log.md) | What has actually been checked, on what, and when — including what has **not**. |
| [docs/roadmap.md](docs/roadmap.md) | What stands between "verified on one cluster" and "a stranger can use it". |


---

## License

MIT — see [LICENSE](LICENSE).

`pi-cage` is an independent project. It is not affiliated with or endorsed by Earendil Inc., the Pi maintainers, `pi-web`, or `pipod`. "Pi" refers to [`@earendil-works/pi-coding-agent`](https://www.npmjs.com/package/@earendil-works/pi-coding-agent).
