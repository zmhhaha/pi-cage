# Roadmap: from "works on my cluster" to "a stranger can use it"

The engineering core of `pi-cage` is done and verified: the container is isolated,
the network boundary holds on a real cluster, and both are checked by scripts that
fail closed. See [verification-log.md](verification-log.md).

What is missing is everything that turns that into something a stranger can pick
up. That gap is the whole reason the earlier research concluded the bottleneck is
distribution rather than code — and it is measurable: [`fkleon/pi-docker`](https://github.com/fkleon/pi-docker)
is careful work with 0 stars.

**Ordered by how much each one blocks a first-time user.**

---

## 1. Publish an image — **done, 2026-10-14**

**Why it was first.** The quickstart was `git clone` → `./build.sh` → run.
[`pi-less-yolo`](https://github.com/cjermain/pi-less-yolo) gets a user running with
`mise run pi`; [`pi-dispatch`](https://github.com/edgehero/pi-dispatch) with a
compose file. Until an image existed, nothing else on this list mattered.

**Done:** `ghcr.io/zmhhaha/pi-cage` is a multi-arch manifest list — index
`sha256:897709bd…`, resolving to `amd64` `sha256:cbd3c196…` and `arm64/v8`
`sha256:b0905fa7…`, tagged `:latest` and `:20261014`. Both were pulled back from
GHCR and confirmed to resolve to the right architecture on the right host.

The two single-arch images came from different hosts and different mirror sets, so
equivalence was checked rather than assumed: **127 packages, identical names and
versions; node v24.21.0 and ttyd 1.7.7 identical; the Pi bundle byte-identical**
across both. Only the `ttyd` binary differs, and that is the per-architecture pin.

**Also done:** the package is **public**, verified by pulling anonymously from a
host with no stored credentials — it resolved the same index digest. So a node
with no `imagePullSecret` can pull it, and both acceptance criteria below hold.

The package is also linked to this repository, so the package page shows the
project rather than an orphan image.

---

## 2. A one-command quickstart — **done, 2026-10-14**

**Done:** the README's first screen is now a pasteable `docker run` line, and it was
run verbatim before being written down. Two things came out of actually trying it:

- **`--network host` is required**, because `serve` binds loopback and a published
  port cannot reach a loopback-only listener. This is why the old
  `docker compose up` line never worked.
- **`PI_CAGE_AUTH_HEADER=` is required** to turn auth off, and the default is the
  opposite: the variable is read with `-` rather than `:-`, so unset means the
  header is *required*. Only an explicit empty value disables it.

**Still open: `docker-compose.yml` is unusable as written.** It publishes
`127.0.0.1:7681:7681` while the container binds loopback — the same contradiction.
Two ways out, and it is a real trade-off rather than a typo:

| Option | Gain | Cost |
|---|---|---|
| `network_mode: host` | Works today; keeps the loopback bind, publishes nothing | Gives up network-namespace isolation, which `verify-hardening.sh` currently asserts as a hardening property |
| Bind `0.0.0.0` + `PI_CAGE_ALLOW_PUBLIC=1` + an authenticating proxy | Keeps the namespace; the shape Kubernetes already uses | Needs a proxy for a single-user local setup, and the header requirement cannot be turned off |

Not resolved here on purpose: the first option means weakening a property the
project advertises, and that should be a decision, not a side effect.

---

## 3. Exercise `run` and `json`

**Why.** `serve` has been exercised on a real cluster (the pane shows Pi's TUI).
**`run` and `json` have never been run at all.** They appear in the README as
supported modes on the strength of upstream's documentation alone, which is
exactly the kind of unverified claim this project exists to avoid.

**Acceptance**

- `pi-server run "reply with the single word ok"` prints `ok` to stdout and exits 0.
- `pi-server json "..."` emits parseable JSONL.
- A non-zero exit is produced for a failed run (the `--print` contract).
- Results recorded in [verification-log.md](verification-log.md).

**Blocked on:** a provider credential. No model call has ever been made from this
image, so this cannot be done without one.

---

## 4. Authentication recipes — **done, 2026-10-14**

**Why.** The design goal was "OIDC **and** reverse proxy, both spelled out". The
README used to say "put an authenticating proxy in front" and stop. The closest
peers either ship auth (`agegr/pi-web`'s `PI_WEB_PASSWORD`) or defer it.

**Done:** [`docs/auth.md`](auth.md) — `oauth2-proxy` with OIDC as a sidecar (the
recommended shape, which keeps the loopback bind) and as a separate pod, plus Caddy
and nginx for people with no IdP.

Written from a **working production `oauth2-proxy` deployment on the same cluster
this project is verified against**, not from the upstream README, and that is where
the useful parts came from:

- **`set_xauthrequest = true`** — without it `oauth2-proxy` never emits
  `X-Auth-Request-Email`, so every request gets `407` *after* a successful login.
  Silent, and the most likely reason a correct OIDC setup still fails.
- **`proxy_websockets = true`** — ttyd is a WebSocket; without it the page loads and
  the terminal never connects.
- Two misconfigurations that stop `oauth2-proxy` from starting, both hit while
  testing: `cookie_secret` must be exactly 16/24/32 bytes, and an email allow-list
  is mandatory.
- Two facts read off the live policies that the sidecar shape depends on:
  `public-egress` selects `role: cage` (so the sidecar needs that label or it cannot
  reach the IdP at all), and `proxy-ingress` admits **only port 7681**, so a sidecar
  on 4180 needs a policy change to be reachable.

**And the thing worth stating loudest**, measured against a running `serve`:
`ttyd` checks that the auth header is present and non-empty and **nothing else**.
`X-Auth-Request-Email: x` gets `200`; `$(id)` gets `200`. The header is a bearer
token, not an identity, and all the actual security is in who can reach the port.

**Not done:** the sidecar manifest has not been applied, and no login has been
completed in a browser — the OIDC round trip and the WebSocket upgrade through a
real proxy are still unverified. Recorded in the table at the end of `auth.md`.

---

## 5. `linux/amd64` — **done, 2026-10-14**

**Why.** Never built, so an x86 user could not run this at all. `core.yaml` no
longer pins ARM64, so the manifests were already waiting.

**Done:** built on a Tencent Cloud VPS (x86) and verified —
`./verify-hardening.sh` passes **22/22, exit code 0**, the same checks that pass on
ARM64. Details in [verification-log.md](verification-log.md).

Two blocked build inputs surfaced on that host and are now overridable:
`github.com` is unreachable there entirely, and `deb.debian.org` stalled for 19
minutes. `--ttyd-base-url` and `--apt-mirror` handle both, and neither weakens a
pin.

**Still open: the `--multiarch` buildx path itself.** arm64 and amd64 both build
and pass, but as two separate single-arch builds on two hosts. One manifest-list
build — and a published image — remains item 1.

---

## 6. SBOM and build provenance — **partly done, 2026-10-14**

**Why.** The project pins the base image by digest, Pi by exact version and `ttyd`
by SHA-256, then ships no way for anyone to check the result. A published image
without an SBOM asks for exactly the trust this project spends its time not asking
for.

**Done: SBOMs exist, and they answer a question nothing else did.** Two SPDX 2.3
documents in [`sbom/`](../sbom/README.md), one per published architecture,
generated with syft from the local image archives — 438 packages each, same names,
same versions, **zero present in only one architecture**. That is a stronger
cross-architecture statement than the package-count comparison it replaces,
because it is derived from the published artifacts rather than from a build log.

**And it found a gap worth stating.** The SBOM covers the Debian packages, the npm
tree and the Node runtime. It does **not** cover `ttyd`: a statically linked C
binary with libwebsockets inside, with no syft cataloguer. `ttyd` is one of the
three pinned inputs to this image, so **the SBOM does not cover the whole supply
chain** and `sbom/README.md` says so where a reader will hit it.

**Also done: the repeatable form.** [`.github/workflows/release.yml`](../.github/workflows/release.yml)
builds both architectures in **one manifest-list build** (the `--multiarch` path
that has never run), generates an SBOM per architecture against the published
digests, requests `--provenance=mode=max --sbom=true` attestations, and creates the
release with both documents attached and the index digest in the notes.

**Not done, and not claimed:**

- **The workflow has never run.** No tag has been pushed since it was written. It
  is a script that has been read, not a process that has executed.
- **No tagged release exists**, so "attached to a release" is met only in the
  weaker form of committed files. The workflow is what makes it true on the next
  tag.
- **The published images carry no OCI labels.** `Config.Labels` is `null`, so
  `org.opencontainers.image.source` is absent and GHCR was linked by hand. The
  Dockerfile now sets the standard label set and `build.sh` supplies the revision,
  based image name and base digest; **the next build applies them natively.** They
  were not back-filled onto the current images, because doing that means either a
  relabelling trick that produces an image no Dockerfile describes, or a rebuild
  that risks package drift between the two architectures — and drift would break
  the equivalence proved above.

---

## Not engineering: telling anyone

Separate track, and free.

- **Talk to the two closest projects.** [`pi-less-yolo`](https://github.com/cjermain/pi-less-yolo)
  and [`pi-dispatch`](https://github.com/edgehero/pi-dispatch) solve neighbouring
  problems and their authors are the most informed reviewers available. Offer
  something (the egress policy and its verifier are MIT) rather than asking for a
  link, and accept silence as a normal outcome.
- **Get it listed.** [`qualisero/awesome-pi-agent`](https://github.com/qualisero/awesome-pi-agent)
  (1,099★) and [`shaftoe/awesome-pi-coding-agent`](https://github.com/shaftoe/awesome-pi-coding-agent)
  (150★) are where people look. This is the cheapest distribution available.
- **Fill in the repository About section.** Description and topics, currently empty.

---

## Under consideration

**Source `ttyd` from its Docker image instead of the GitHub release.** The image
`tsl0922/ttyd:1.7.7` is multi-arch, and its `/usr/bin/ttyd` is **byte-identical**
to the release asset — confirmed by extracting it and matching the SHA-256 already
pinned in the Dockerfile. That would remove the build's only dependency on
`github.com`, which is unreachable on some networks while registries (needed
anyway, for the base image) keep working.

Not done because it changes the transport for something already pinned and
verified, and the current failure has a workaround (`--ttyd-base-url`) that keeps
the digest check in force. Revisit if a second person hits a blocked `github.com`.

---

## Explicitly not planned

- **A web UI.** Two projects do this well and one is 7,315★.
- **A job queue or spend caps.** [`pi-dispatch`](https://github.com/edgehero/pi-dispatch)
  is ahead and MIT.
- **A Docker socket mount, host path mounts, or a host-execution escape hatch.**
  That is the thing this project exists not to do. See [SECURITY.md](../SECURITY.md).
- **Multi-tenancy.** One container, one trust domain.
