#!/usr/bin/env bash
#
# Check that a built pi-cage image actually has the properties README.md and
# THREAT-MODEL.md claim. Run it against a real container, not against the
# Dockerfile -- the point is to catch a flag that is present in the file and
# absent in the running container.
#
#   ./verify-hardening.sh                      # builds and inspects a throwaway run
#   ./verify-hardening.sh pi-cage:local        # inspect an existing image
#
# Exit code 0 means every check passed.

set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

IMAGE="${1:-pi-cage:local}"
NAME="pi-cage-verify-$$"
FAILED=0

pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*" >&2; FAILED=1; }
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

command -v docker >/dev/null 2>&1 || { echo 'docker is required' >&2; exit 2; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "image not found: $IMAGE -- run ./build.sh first" >&2; exit 2; }

echo "Verifying ${IMAGE}"

# Start a container so we can inspect runtime state as well as image metadata.
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" "$IMAGE" run "reply with the single word ok" >/dev/null 2>&1 || true

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

insp() { docker inspect "$NAME" --format "$1" 2>/dev/null || echo '<none>'; }

echo 'Image configuration'
check 'runs as an unprivileged uid'      '10001:10001' "$(docker image inspect "$IMAGE" --format '{{.Config.User}}')"
check 'default command is serve'         'serve'       "$(docker image inspect "$IMAGE" --format '{{join .Config.Cmd " "}}')"
check 'has an entrypoint'                'true'        "$(docker image inspect "$IMAGE" --format '{{if .Config.Entrypoint}}true{{else}}false{{end}}')"

echo 'Runtime isolation (docker run defaults)'
check 'read-only root filesystem'        'true'        "$(insp '{{.HostConfig.ReadonlyRootfs}}')"
check 'all capabilities dropped'         '[ALL]'       "$(insp '{{.HostConfig.CapDrop}}' | tr -d ' ')"

echo 'Mounts -- nothing from the host may appear here'
mounts="$(insp '{{range .Mounts}}{{.Source}} {{end}}')"
case "$mounts" in
  *docker.sock*) fail "a Docker socket is mounted: $mounts" ;;
  *)             pass 'no Docker socket mounted' ;;
esac
case "$mounts" in
  *"/home "*|*"/srv "*|*"/opt "*) fail "a host system path is mounted: $mounts" ;;
  *)                             pass 'no host system paths mounted' ;;
esac

echo 'Refusals (these MUST fail)'
public_bind_failed=0
docker run --rm "$IMAGE" serve --bind 0.0.0.0 --port 7681 >/dev/null 2>&1 || public_bind_failed=1
if [ "$public_bind_failed" = 1 ] && [ "${PI_CAGE_ALLOW_PUBLIC:-0}" != 1 ]; then
  pass 'refuses a non-loopback bind without opt-in'
else
  fail 'accepted a non-loopback bind -- serve mode is not fail-closed'
fi

echo
if [ "$FAILED" = 0 ]; then
  echo 'All checks passed.'
else
  echo 'Some checks FAILED. Do not publish this image.' >&2
fi
exit "$FAILED"
