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

## 1. Publish an image

**Why it is first.** Today the quickstart is `git clone` → `./build.sh` → run.
[`pi-less-yolo`](https://github.com/cjermain/pi-less-yolo) gets a user running with
`mise run pi`; [`pi-dispatch`](https://github.com/edgehero/pi-dispatch) with a
compose file. Until an image exists, nothing else on this list matters, and the
Kubernetes manifests stay broken by default.

**Do**

```bash
REGISTRY=ghcr.io/zmhhaha IMAGE=pi-cage ./build.sh --multiarch --push
```

**Acceptance**

- `docker run --rm ghcr.io/zmhhaha/pi-cage:<tag> pi --version` works on both
  architectures.
- The `deploy/k8s/kustomization.yaml` default points at it, so
  `kubectl apply -k deploy/k8s` no longer produces `ImagePullBackOff`.

**Blocked on:** a GHCR account with `write:packages` and a `docker login`. Nobody
else can do this step.

---

## 2. A one-command quickstart

**Why.** The README's first screen should be one line a user can paste. Right now
it is a build from source.

**Depends on 1.**

**Do**

```bash
docker run --rm -it -v pi-home:/home/pi -v "$PWD:/workspace" \
  ghcr.io/zmhhaha/pi-cage:latest run "summarise this repository"
```

…plus the hardened Compose path, which already exists.

**Acceptance**

- Both lines are in the README above the fold and have been run, verbatim, on a
  clean machine.
- The `run` line is on this list as item 3 — do not document it before it works.

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

## 5. `linux/amd64`

**Why.** Never built. An x86 user cannot run this at all, which halves the
audience before anything else is considered. `core.yaml` no longer pins ARM64, so
the manifests are ready.

**Do**

```bash
./build.sh --multiarch          # buildx, amd64 + arm64, pushes
```

**Acceptance:** both architectures pass `./verify-hardening.sh`; the `arm64` run is
already recorded, the `amd64` one added alongside it.

**Blocked on:** a build environment for amd64 — either an x86 machine with Docker
or `binfmt_misc`/qemu registered on the ARM64 builder, which the build host does
not currently have. **Check before promising the multiarch path works.**

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
