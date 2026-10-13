# Prior art: who else runs Pi on a server (survey, 2026-10-13)

`pi-cage` exists because of this survey, not in spite of it. If you are deciding
whether to use this project, read the alternatives first — several of them are
more mature than this one and may fit you better.

> **Numbers are a single-day snapshot** taken from the GitHub API on 2026-10-13.
> Stars move. Re-check before quoting any of this.

---

## The landscape

### Upstream

| Project | ★ | License | What it is |
|---|---|---|---|
| [earendil-works/pi](https://github.com/earendil-works/pi) | 114,685 | MIT | The coding agent CLI. No official image, no HTTP/server mode. Ships `--print`, `--mode json` and `--mode rpc` (JSONL over stdio). |

Upstream's own position, from its security documentation: Pi has **no built-in
sandbox**, commands run with the permissions of the account that started it, and
isolation is something you supply with a container, VM or sandbox.

### Session platforms and web UIs — the crowded part

| Project | ★ | License | Note |
|---|---|---|---|
| [jmfederico/pi-web](https://github.com/jmfederico/pi-web) | 873 | MIT | The incumbent. Rich web UI, multi-machine fleet, plugins, and its own first-party `docker/` runtime. |
| [open-mercato/cezar](https://github.com/open-mercato/cezar) | 649 | MIT | Orchestrator / ADE, "locally or 24/7 on your own server". |
| [code-yeongyu/senpi](https://github.com/code-yeongyu/senpi) | 477 | MIT | A Pi fork/distribution. 407 open issues — a caution about fork maintenance cost. |
| [pi-pod/pipod](https://github.com/pi-pod/pipod) | 160 | **AGPL-3.0** | The closest thing to a full "self-hosted Pi server": control plane, sandbox service, Postgres, Zitadel OIDC, iOS and Android apps, Compose install. A hosted tier is planned. |
| [Epsilondelta-ai/pi-web](https://github.com/Epsilondelta-ai/pi-web) | 58 | MIT | Go web UI. Stale since 2026-07. |
| [ravshansbox/pi-web](https://github.com/ravshansbox/pi-web) | 6 | MIT | Another web UI. |

**Do not build another one of these.** `pi-cage` deliberately does not.

### Remote clients

| Project | ★ | Note |
|---|---|---|
| [Dwsy/pi-session-manager](https://github.com/Dwsy/pi-session-manager) | 196 | Browse/search/resume sessions |
| [ayagmar/pi-mobile](https://github.com/ayagmar/pi-mobile) | 110 | Android client over `pi --mode rpc` |
| [MaliNamNam/pi-phone](https://github.com/MaliNamNam/pi-phone) | 57 | Phone-first web UI over RPC + WebSocket |

Their popularity is the demand signal: people want to drive a Pi session from
somewhere other than the machine it runs on.

### Plain containerisation — where everyone stopped

| Project | ★ | Note |
|---|---|---|
| [gni/pi-coding-agent-container](https://github.com/gni/pi-coding-agent-container) | 56 | docker compose |
| [fkleon/pi-docker](https://github.com/fkleon/pi-docker) | **0** | Rootless Podman, five language variants, named volumes. Well made. 0 stars. |
| [valentinsavenko/pi-docker](https://github.com/valentinsavenko/pi-docker) | **0** | — |
| [bon5co/pi-web-railway](https://github.com/bon5co/pi-web-railway) | **0** | `pi-web` behind Caddy basic auth. Correct instinct, no distribution. |

**The lesson these three teach is the important one for this project:** a
Dockerfile is not a product. `fkleon/pi-docker` is careful work and nobody
found it. Distribution and documentation matter as much as the code — which is
why this repository ships a threat model and a hardening verifier rather than
just a build.

---

## Why `pi-web` is not the answer here (and why it is for most people)

`pi-web`'s `docker/README.md` states its trust model plainly:

> By design, the runtime containers get **deliberate host access** so PI WEB
> agents can work on real host paths:
> - **`/var/run/docker.sock` is mounted into the containers. The Docker socket
>   is root-equivalent on the Docker host.**
> - On native Linux Docker Engine, existing `/home`, `/srv`, and `/opt` paths
>   are mounted **read/write**, `/` is mounted **read-only at `/host`**, and
>   `hostexec` can run explicit commands in the Linux host namespaces.

That is a coherent product: its value proposition is running agents where your
real code, tools and credentials already are. It is also the exact opposite of
what `pi-cage` wants.

The same manual notes that the installer:

> …**fails closed on unknown or unsupported Docker setups**, such as remote
> Docker contexts, `DOCKER_HOST` overrides outside the supported local Unix
> socket, **rootless/alternate Linux sockets**, Docker Desktop for Linux,
> Colima, or OrbStack.

A Kubernetes Pod has no Docker socket at all, so it lands outside that
supported set. Wrapping `pi-web`'s Docker layer into a cluster is therefore not
a small fork — it is fighting the design.

**If you want an agent on your own machine, use `pi-web`.** It is better at that
than this project will ever be.

---

## What is genuinely unclaimed

Checked against `pi-web`'s 438-line Docker manual by keyword: `oidc`, `oauth`,
`basic auth`, `caddy`, `traefik`, `nginx`, `arm64`, `amd64`, `platform`,
`non-root`, `--user`, `seccomp`, `sbom`, and pinned digests all return **zero
hits**. (`arm64` is mentioned once indirectly, as "the selected architecture",
with no published multi-arch image.)

So, in rough order of confidence:

1. **A container that is the boundary** — no Docker socket, no host paths, no
   host execution. Nobody ships this, and `pi-web` will not, by design.
2. **Kubernetes delivery** — nothing in the ecosystem ships manifests or a
   chart. `pipod` and `pi-web` are both Compose-or-systemd.
3. **Multi-arch, ARM64-verified** — no project publishes a multi-arch image.
4. **Bundled authentication** — everyone pushes this to the operator's reverse
   proxy. `pi-cage` keeps that boundary too, but at least makes it explicit and
   fails closed.
5. **Headless / CI / job-shaped usage** — everything in the ecosystem is
   session-shaped; nobody packages `pi --print` as a task primitive.

`pi-cage` targets (1), (2), (3) and (5), and documents (4) instead of
pretending to solve it.

---

## Things this project will not do, because they are taken

- **Another web UI** — `pi-web` (873★, daily commits) and `pipod` (native apps).
- **Another session-hosting control plane** — `pipod`, with a hosted tier behind it.
- **Another Pi fork or distribution** — `senpi` exists with 407 open issues.
- **A public-exposure tunnel** — `pi-web`'s maintainer is building `safe-tunnel`
  (Cloudflare WSS/443) himself. Do not collide with a maintainer's roadmap.

---

## A note on the AGPL

`pipod` is AGPL-3.0. If you build on it and offer it over a network, you must
publish your modifications. `pi-web` and upstream Pi are MIT. `pi-cage` is MIT.
If permissive licensing matters to you — and for a deployment layer that other
tools will vendor, it usually does — that difference decides which codebase you
can read *and copy* versus merely read.

---

## Sources

All fetched 2026-10-13. Star counts, licences and last-push dates come from
`api.github.com/repos/{owner}/{repo}`; download counts from
`api.npmjs.org/downloads/point/last-month/{package}`.

- Upstream: [pi](https://github.com/earendil-works/pi) · [pi.dev docs](https://pi.dev/docs/latest) · [pi-chat](https://github.com/earendil-works/pi-chat) (420★, official Discord/Telegram bridge)
- `pi-web`: [repo](https://github.com/jmfederico/pi-web) · [docker/README.md](https://github.com/jmfederico/pi-web/blob/main/docker/README.md) · [Docker runtime PR #42](https://github.com/jmfederico/pi-web/pull/42) · [Nix packaging precedent #180](https://github.com/jmfederico/pi-web/issues/180) · [open hardening issue #154](https://github.com/jmfederico/pi-web/issues/154) · [safe-tunnel #155](https://github.com/jmfederico/pi-web/issues/155)
- [pipod](https://github.com/pi-pod/pipod) · [cezar](https://github.com/open-mercato/cezar) · [senpi](https://github.com/code-yeongyu/senpi)
