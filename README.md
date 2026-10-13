# pi-cage

**An isolation-first container for the [Pi coding agent](https://github.com/earendil-works/pi).**

Pi has no built-in sandbox — by design, its `bash` tool runs commands with the permissions of whatever account started it. `pi-cage` takes the position that **the container is the boundary**: no Docker socket, no host paths, no `hostexec`, no cluster credentials. The agent gets a workspace and a network policy, and nothing else.

> ### ⚠️ Status: scaffold, pre-alpha
>
> **No image has been published. The build has never been run.**
>
> What exists today is the repository skeleton: Dockerfile, entrypoint, hardened Compose reference, Kubernetes manifests, and the security documents. Everything in this README describes **intended** behaviour. Treat every guarantee below as a claim to be verified, not a fact — the verification steps are listed so you can check them yourself, and [THREAT-MODEL.md](THREAT-MODEL.md) records what is not defended.

---

## Quick start

```bash
git clone https://github.com/zmhhaha/pi-cage.git
cd pi-cage
./build.sh                       # local single-arch image
docker compose run --rm pi-cage run "summarise this repository"
```

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

---

## Why this exists

The Pi ecosystem already has excellent ways to run agents on a machine you control. `pi-cage` is not a better version of them — it makes **the opposite trade-off on purpose**.

| | [`pi-web`](https://github.com/jmfederico/pi-web) (873★) | [`pipod`](https://github.com/pi-pod/pipod) (160★) | **pi-cage** |
|---|---|---|---|
| Model | Host-integrated web UI | Self-hosted session platform | **Isolated container** |
| Host access | **Docker socket + `/home` `/srv` `/opt` read-write + `hostexec`** | Sandbox service per pod | **None** |
| Server shape | `sessiond` + `web`, systemd or its own Compose | Control plane + Postgres + OIDC + mobile apps | **One container** |
| Auth | Bring your own reverse proxy | Zitadel OIDC | **Bring your own proxy, or none on loopback** |
| Kubernetes | ✗ (installer fails closed without a Docker socket) | ✗ (Compose) | **✓ manifests included** |
| License | MIT | AGPL-3.0 | MIT |

`pi-web`'s Docker containers deliberately mount the Docker socket — *"root-equivalent on the Docker host"* — because its whole value proposition is letting the agent work where your real code, tools and credentials live. That is a defensible design. It is also the thing `pi-cage` refuses to do.

**Use `pi-web` if you want an agent on your own machine. Use `pi-cage` if you want an agent somewhere you would not hand over a shell.**

The full competitive survey, with star counts and source links, is in [docs/prior-art.md](docs/prior-art.md).

---

## What it is not

- **Not a web UI.** No chat interface is written here. `serve` exposes a terminal; if you want a rich UI, install [`pi-web`](https://github.com/jmfederico/pi-web) inside your own image (`custom-image.d` equivalent) — see [docs/prior-art.md](docs/prior-art.md).
- **Not multi-tenant.** One container, one user, one agent. There is no account system and none is planned.
- **Not a host-development tool.** If you need the agent to touch host paths, this is the wrong project — use `pi-web`.
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

Every item is checkable on a running container:

```bash
docker inspect pi-cage --format '{{json .Config.User}}'                 # 10001:10001
docker inspect pi-cage --format '{{json .HostConfig.ReadonlyRootfs}}'   # true
docker inspect pi-cage --format '{{json .HostConfig.CapDrop}}'          # ["ALL"]
docker inspect pi-cage --format '{{json .HostConfig.SecurityOpt}}'      # no-new-privileges:true
docker inspect pi-cage --format '{{range .Mounts}}{{.Source}} {{end}}'  # no docker.sock, no host paths
```

| Property | How |
|---|---|
| Non-root | `USER 10001:10001`, `runAsNonRoot` in Kubernetes |
| Read-only root filesystem | `read_only: true`; `/tmp` and `/run` are `noexec,nosuid` tmpfs |
| No capabilities | `cap_drop: [ALL]` |
| No privilege escalation | `no-new-privileges:true`, seccomp `RuntimeDefault` |
| No host access | No Docker socket, no host path mounts, no `hostexec` |
| Pinned supply chain | Base image pinned by digest, Pi pinned to an exact version, both recorded in `rendered/` |
| Multi-arch | `linux/amd64` and `linux/arm64` (ARM is the primary target — see below) |

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

The last two matter: a distribution `ttyd` without `--auth-header` or `--check-origin` would silently drop an access control, and an unpinned Pi would let a rebuild change the CLI contract underneath you.

---

## Documents

| File | Contents |
|---|---|
| [THREAT-MODEL.md](THREAT-MODEL.md) | Assets, adversaries, what is and is **not** defended. Read this before exposing anything. |
| [SECURITY.md](SECURITY.md) | How to report a vulnerability. |
| [docs/prior-art.md](docs/prior-art.md) | The 2026-10 competitive survey this design came from. |

---

## License

MIT — see [LICENSE](LICENSE).

`pi-cage` is an independent project. It is not affiliated with or endorsed by Earendil Inc., the Pi maintainers, `pi-web`, or `pipod`. "Pi" refers to [`@earendil-works/pi-coding-agent`](https://www.npmjs.com/package/@earendil-works/pi-coding-agent).
