# pi-cage

**An isolation-first container for the [Pi coding agent](https://github.com/earendil-works/pi).**

Pi has no built-in sandbox — by design, its `bash` tool runs commands with the permissions of whatever account started it. `pi-cage` takes the position that **the container is the boundary**: no Docker socket, no host paths, no `hostexec`, no cluster credentials. The agent gets a workspace and a network policy, and nothing else.

> ### ⚠️ Status: pre-alpha, published and verified on both architectures
>
> **`ghcr.io/zmhhaha/pi-cage:latest` is a multi-arch manifest list** — index `sha256:897709bd…`, resolving to `amd64` `sha256:cbd3c196…` and `arm64/v8` `sha256:b0905fa7…`. Both were pulled back from GHCR and confirmed to resolve per architecture, and the package is **public**: a host with no stored credentials pulled it anonymously. [`./verify-hardening.sh`](verify-hardening.sh) passes **22/22, exit code 0** on each, and [`verify-network-boundary.sh`](verify-network-boundary.sh) passes on a real 6-node ARM64 Calico cluster.
>
> **Verified so far:** both architectures build; `ttyd` is downloaded and SHA-256 verified, and the pin was confirmed against a second transport; Pi installs at an exact pinned version; the build-time gates in [`docker/assert-image.sh`](docker/assert-image.sh) pass; the container hardening holds on a real container — read-only root filesystem, all capabilities dropped, no-new-privileges, **no Docker socket, no host paths**; every internal target and the metadata address are refused from inside the container; an unlabelled Pod cannot reach the web terminal while a labelled one can, and gets `407` without the auth header; all four fail-closed refusals refuse; and **the agent has been given real work** — `run` and `json` both succeed, and a task that tried to write outside its workspace was refused by the read-only root and reported the real `EROFS` error.
>
> **Verified end to end:** a login completed in a real browser against a real IdP, through an `oauth2-proxy` sidecar, and reached a working terminal — WebSocket upgrade included. **Not yet verified:** `docker-compose.yml` is currently unusable — see the quick start. [THREAT-MODEL.md](THREAT-MODEL.md) records what is not defended at all; [docs/verification-log.md](docs/verification-log.md) records what was checked, when, and on what.


---

## Quick start

The image is published as a **multi-arch manifest list**, so one tag serves x86-64
and ARM64:

```bash
mkdir -p workspace && sudo chown 10001:10001 workspace   # see below
docker run --rm --network host -e PI_CAGE_AUTH_HEADER= \
  -v "$PWD/workspace:/workspace" \
  ghcr.io/zmhhaha/pi-cage:latest serve
# open http://127.0.0.1:7681
```

Every part of that line is load-bearing, and each was measured rather than
assumed:

- **`--network host` is not decoration.** `serve` binds `127.0.0.1` *inside* the
  container and refuses anything else without an explicit opt-in. A **published
  port cannot reach a loopback-only listener**, because Docker's proxy connects to
  the container's IP: `docker run -p 127.0.0.1:7681:7681 … serve` fails with
  `Connection reset by peer`. Sharing the host's network namespace is what makes
  `127.0.0.1` mean the same address on both sides. **Nothing is published, so
  nothing is exposed beyond loopback** — that is the whole point of the trade.
- **`PI_CAGE_AUTH_HEADER=` disables the auth header**, which otherwise defaults to
  `X-Forwarded-Email` (the variable is read with `-`, not `:-`, so *unset* means
  the header is required and only an explicit empty value turns it off). Acceptable
  only because the bind is loopback and the browser is on the same machine.
- **`chown 10001:10001` is required**: the container runs as uid `10001` and a bind
  mount carries the host's ownership. Without it Pi can read your project and
  cannot write to it.

There is no web terminal in this form:

```bash
docker run --rm -v "$PWD/workspace:/workspace" \
  ghcr.io/zmhhaha/pi-cage:latest run "summarise this repository"
```

> ⚠️ **`run` and `json` have never been executed.** They are documented from
> upstream's spec, not from a test — no model credential has ever been configured
> in this image. Tracked in [docs/roadmap.md](docs/roadmap.md). Treat them as
> unverified until that changes.

Kubernetes:

```bash
kubectl apply -k deploy/k8s
```

> The package is **public**, and that was verified the only way that counts:
> a host with **no stored credentials** (`docker logout ghcr.io`) pulled
> `:latest` anonymously and resolved the same index digest. Your nodes need no
> `imagePullSecret`.
>
> [`deploy/k8s/kustomization.yaml`](deploy/k8s/kustomization.yaml) is the single
> place to point it at a different registry, for a fork or an air-gapped cluster;
> the cases and their exact
> commands are in [deploy/k8s/README.md](deploy/k8s/README.md).

> ⚠️ **`docker-compose.yml` does not work as written.** It publishes
> `127.0.0.1:7681:7681` while the container binds loopback, which is the same
> contradiction as above. `docker compose` needs either `network_mode: host` (which
> gives up the network-namespace isolation that `verify-hardening.sh` currently
> asserts) or a non-loopback bind plus an authenticating proxy. That is a real
> trade-off, not a typo, so it is recorded in
> [docs/roadmap.md](docs/roadmap.md) rather than resolved silently here.

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

`serve` trusts a header injected by whatever sits in front of it, named by `PI_CAGE_AUTH_HEADER` (`X-Forwarded-Email` by default). Put a real proxy there. The Kubernetes manifests pair with any ingress that sets that header; with Compose, put Caddy, Traefik, `oauth2-proxy` or Tailscale in front.

**The name must match what your proxy actually sends, and `oauth2-proxy` makes that easy to get wrong.** In reverse-proxy mode it sends `X-Forwarded-Email` — that is the default, through `--pass-user-headers`. Its `--set-xauthrequest` flag sets `X-Auth-Request-*` as *response* headers for nginx `auth_request` mode and does **not** put them on the request handed upstream. Choosing the wrong one gives a successful login, an `AuthSuccess` in the proxy log, and then `407` from `serve` — which a browser reports as `ERR_UNEXPECTED_PROXY_AUTH`, blaming the one component that is working. The full account is in [docs/auth.md](docs/auth.md).

**The header is a bearer token, not an identity.** `ttyd` checks that it is present and non-empty and nothing else — a value of `x` is accepted. So the header is worth exactly as much as your control over who can reach the port and who can set it, and a NetworkPolicy or a private network is doing the real work. This is measured, not assumed; the requests and their status codes are in [docs/auth.md](docs/auth.md).

Copy-pasteable configurations for `oauth2-proxy` with OIDC (sidecar and separate-pod), and for Caddy or nginx without an IdP, are in **[docs/auth.md](docs/auth.md)** — including the three settings that decide whether it works at all, two of which fail silently after a successful login.

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
| [docs/auth.md](docs/auth.md) | `oauth2-proxy`, Caddy and nginx recipes — and the fact that the auth header is a bearer token, not an identity. |
| [sbom/](sbom/README.md) | SPDX 2.3 documents for both published images — and what they do **not** cover. |


---

## License

MIT — see [LICENSE](LICENSE).

`pi-cage` is an independent project. It is not affiliated with or endorsed by Earendil Inc., the Pi maintainers, `pi-web`, or `pipod`. "Pi" refers to [`@earendil-works/pi-coding-agent`](https://www.npmjs.com/package/@earendil-works/pi-coding-agent).
