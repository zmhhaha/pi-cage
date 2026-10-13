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

## Not yet verified

| Claim | Status |
|---|---|
| The Kubernetes network boundary | **Never run against a cluster.** `verify-network-boundary.sh` exists and its `--explain` path has been exercised, but no cluster verdict has been recorded. |
| `linux/amd64` | **Never built.** Only ARM64 has been built. |
| Multi-arch buildx path (`./build.sh --multiarch`) | **Never run.** |
| Behaviour under a real workload | **Never run.** No agent session has been executed in this image. |
| Behaviour under attack | **Never attempted.** |
| `serve` mode end to end, through a proxy | **Never run.** `ttyd` + `tmux` + `pi` has not been exercised interactively. |

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
