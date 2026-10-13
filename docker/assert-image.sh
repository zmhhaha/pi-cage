#!/usr/bin/env bash
#
# Build-time gates. Fails the image build rather than shipping one that cannot
# honour the guarantees in README.md / THREAT-MODEL.md.
#
# Runs inside the image as root, before the unprivileged user is created.

set -Eeuo pipefail

fail() { printf 'assert-image: FAIL: %s\n' "$*" >&2; exit 1; }

# 1. Node floor. Pi's package.json declares engines.node >= 22.19.0. The tag
#    name does not guarantee a patch level, so read the real version back.
node -e '
const need = [22, 19];
const got = process.versions.node.split(".").map(Number);
if (got[0] < need[0] || (got[0] === need[0] && got[1] < need[1])) {
  console.error("assert-image: FAIL: Node " + process.versions.node +
                " is below the required " + need.join("."));
  process.exit(1);
}'

# 2. Pi is installed and runnable. A resolvable package that will not start is
#    exactly the failure a tag-only check misses.
command -v pi >/dev/null 2>&1 || fail 'pi is not on PATH'

# 3. ttyd supports every flag serve mode relies on. This is the gate that keeps
#    a stale distribution build from silently dropping authentication or origin
#    checking.
ttyd_help="$(ttyd --help 2>&1 || true)"
[ -n "$ttyd_help" ] || fail 'ttyd --help produced no output'
for flag in --interface --port --writable --max-clients --check-origin --auth-header; do
  case "$ttyd_help" in
    *"$flag"*) ;;
    *) fail "ttyd does not support ${flag}; serve mode would lose an access control.
       Install a newer ttyd (upstream static binary) or remove serve mode." ;;
  esac
done

# 4. Tools the modes shell out to.
#
# `fd` is in this list for a specific reason: when it is absent, Pi downloads a
# binary at runtime ("fd not found. Downloading..."). That would make an image
# with a pinned supply chain fetch an unpinned executable on first use, so a
# missing fd must fail the BUILD, not be papered over later.
for tool in tmux git rg tini fd; do
  command -v "$tool" >/dev/null 2>&1 || fail "${tool} is missing"
done

# 5. Explicitly assert we did NOT inherit a Docker client that could reach a
#    host daemon. Nothing mounts the socket at runtime either -- this is the
#    belt to that suspenders.
[ ! -S /var/run/docker.sock ] || fail 'a Docker socket is present in the build context'

printf 'assert-image: ok -- node %s | pi %s | ttyd %s\n' \
  "$(node -v)" \
  "$(pi --version 2>/dev/null || echo unknown)" \
  "$(ttyd --version 2>/dev/null || echo unknown)"
