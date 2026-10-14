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

**Still open:** the GHCR package is **private** by default. Until its visibility is
switched to public, a cluster without an `imagePullSecret` cannot pull it — so the
second acceptance criterion below is not met yet.

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

## 4. Two authentication recipes

**Why.** The design goal was "OIDC **and** reverse proxy, both spelled out". The
README currently says "put an authenticating proxy in front" and stops. The
closest peers either ship auth (`agegr/pi-web`'s `PI_WEB_PASSWORD`) or defer it;
nobody writes the recipe down.

**Do** — `docs/auth.md` with two copy-pasteable configurations:

1. **`oauth2-proxy` in front of `serve`**, injecting `X-Auth-Request-Email`, which
   `serve` already requires — plus the Casdoor/OIDC client settings.
2. **A plain reverse proxy** (Caddy or nginx) with any auth scheme, for people who
   do not run an IdP.

Both must state plainly that `serve` trusts the header and that binding publicly
without a proxy is refused by design.

**Acceptance:** someone can copy a config, change two values, and be authenticated.
**Not blocked on anything.** This is the only item on the list that is pure writing.

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

## 6. SBOM and build provenance

**Why.** The project pins the base image by digest, Pi by exact version and `ttyd`
by SHA-256, then ships no way for anyone to check the result. A published image
without an SBOM asks for exactly the trust this project spends its time not
asking for.

**Acceptance:** an SBOM (`syft`) and provenance (`buildx --provenance=true`)
attached to a tagged release, with the digest in the release notes.

**Blocked on:** 1 (there must be a release first).

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
