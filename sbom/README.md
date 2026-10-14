# SBOMs for the published images

Two SPDX 2.3 documents, gzipped, one per published architecture. They describe the
images that are actually in the registry, by digest — not a build that happened to
be nearby.

| File | Describes | Manifest digest | Built on |
|---|---|---|---|
| `pi-cage-arm64.spdx.json.gz` | `linux/arm64/v8` | `sha256:b0905fa77029ad7520e6433c1462298435eb318350364b401752e11aad086e19` | `arm-cluster-master` |
| `pi-cage-amd64.spdx.json.gz` | `linux/amd64` | `sha256:cbd3c1960ddc76d835d32afd22b2cb70be6b5ef071c2892aa0cf3cdd53ff6cd9` | an x86 VPS |

Both are reachable through the index
`sha256:897709bdb3f6a123fd3acd5da3f02f9491a217f1c0b67ab577c61dd965b868b2`,
tagged `:latest` and `:20261014`.

## How they were produced

```bash
# on a host that already has the image locally
docker save ghcr.io/zmhhaha/pi-cage:arm64 -o /tmp/pi-cage-arm64.tar
docker run --rm -v /tmp:/work anchore/syft:latest \
  docker-archive:/work/pi-cage-arm64.tar -o spdx-json > sbom-arm64.spdx.json
gzip -9 sbom-arm64.spdx.json
```

The archive route is deliberate. Pointing syft at `registry:ghcr.io/...` failed on
both hosts — the blob fetch is reset from mainland China (`connection reset by
peer` against GitHub's CDN) — and a document that cannot be regenerated where it
was made is not much of a document. Analysing a local archive needs no network at
all.

## What these cover, and what they do not

**Covered — 438 packages, and the same 438 on both architectures:**

- the Debian packages (127 of them)
- the npm tree, including `@earendil-works/pi-coding-agent@0.99.2` and all of its
  transitive dependencies
- the Node runtime itself, `node@24.21.0`

**Not covered: `ttyd`.**

`ttyd` is a statically linked C binary with libwebsockets inside it, fetched from
an upstream release and verified by SHA-256. syft has no cataloguer for it, so it
appears in the file list as `usr/local/bin/ttyd` with **no version and no
dependencies** — and `libwebsockets` does not appear at all.

This matters, because `ttyd` is one of the three pinned inputs to this image. Two
of them — the base image and Pi — are covered here. **For `ttyd`, the authoritative
record is the SHA-256 in the `Dockerfile`, not this SBOM.** Do not read these
documents as covering the whole supply chain; they cover the package-managed part
of it.

## The cross-architecture result

Comparing the two documents by `name@version`:

| | arm64 | amd64 |
|---|---|---|
| Packages | 438 | 438 |
| Unique `name@version` | 425 | 425 |
| Present in only one | **0** | **0** |

Identical inventories, including `ripgrep@13.0.0-4+b2`, `fd-find@8.6.0-3`,
`tmux@3.3a-3` and `openssh-client@1:9.2p1-2+deb12u10`. The only intended difference
between the two images is the `ttyd` binary, which is exactly the thing this
document cannot see — check the Dockerfile's two `TTYD_SHA256_*` values for that.

## Why they are committed and not only attached to a release

There is no release yet, and an acceptance criterion that says "attached to a
release" should not be met by asserting it. The files are small when gzipped
(~660 KB each) and immutable: they are named by the digest they describe, so they
cannot go stale, only accumulate.

Future releases attach them as assets instead — see
[`.github/workflows/release.yml`](../.github/workflows/release.yml), which builds
both architectures in one manifest-list build, generates an SBOM per architecture
against the published digests, and attaches them to the tag.
