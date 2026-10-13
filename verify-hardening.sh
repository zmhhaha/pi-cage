#!/usr/bin/env bash
#
# Check that a built pi-cage image AND the reference run configuration actually
# have the properties README.md and THREAT-MODEL.md claim.
#
# The distinction this script keeps explicit, because muddling it is misleading:
#
#   A. IMAGE properties       baked in. An operator cannot turn them off.
#   B. RUN-CONFIG properties  come from docker-compose.yml / deploy/k8s. They
#                             are NOT in the image, and a plain `docker run` has
#                             none of them. Checking them against a bare
#                             container reports failures that say nothing about
#                             the image -- and hides the real question, which is
#                             whether the shipped run configuration applies them.
#
#   ./verify-hardening.sh                          # verify pi-cage:latest
#   ./verify-hardening.sh pi-cage:20261013T060112Z
#
# Exit code 0 means every check passed.

set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

IMAGE="${1:-pi-cage:latest}"
COMPOSE="${COMPOSE:-docker-compose.yml}"
NAME="pi-cage-verify-$$"
FAILED=0

pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*" >&2; FAILED=1; }
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
grep_has() { # grep_has <description> <extended-regex>
  if grep -Eq "$2" "$COMPOSE"; then pass "$1"; else fail "$1 (not found in ${COMPOSE}: $2)"; fi
}
grep_hasnt() {
  if grep -Eq "$2" "$COMPOSE"; then fail "$1 (found in ${COMPOSE}: $2)"; else pass "$1"; fi
}

command -v docker >/dev/null 2>&1 || { echo 'docker is required' >&2; exit 2; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "image not found: ${IMAGE} -- run ./build.sh first" >&2; exit 2; }

echo "Verifying ${IMAGE}"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker rm -f "$NAME" >/dev/null 2>&1 || true

img() { docker image inspect "$IMAGE" --format "$1" 2>/dev/null || echo '<none>'; }

# ---------------------------------------------------------------------------
echo
echo 'A. Image properties (baked in; an operator cannot turn these off)'
# ---------------------------------------------------------------------------
check 'runs as an unprivileged uid' '10001:10001' "$(img '{{.Config.User}}')"
check 'default command is serve'    'serve'       "$(img '{{join .Config.Cmd " "}}')"
if [ "$(img '{{if .Config.Entrypoint}}yes{{end}}')" = 'yes' ]; then
  pass 'has an entrypoint (modes dispatched by the script, not a shell string)'
else
  fail 'no entrypoint'
fi

# ---------------------------------------------------------------------------
echo
echo "B. Reference run configuration (${COMPOSE}) -- static"
# ---------------------------------------------------------------------------
if [ -f "$COMPOSE" ]; then
  grep_has   'runs as a non-root uid'        '^[[:space:]]*user:[[:space:]]*"?10001:10001'
  grep_has   'read-only root filesystem'     '^[[:space:]]*read_only:[[:space:]]*true'
  grep_has   'drops ALL capabilities'        '^[[:space:]]*-[[:space:]]*ALL[[:space:]]*$'
  grep_has   'no-new-privileges'             'no-new-privileges:true'
  grep_has   'writable tmpfs for /tmp'       '/tmp:rw'
  grep_has   'binds loopback only'           '127\.0\.0\.1:[0-9]+:[0-9]+'
  grep_hasnt 'no Docker socket mount'        'docker\.sock'
  grep_hasnt 'no --privileged'               'privileged:[[:space:]]*true'
  grep_hasnt 'no host networking'            'network_mode:[[:space:]]*host'
else
  fail "cannot find ${COMPOSE}"
fi

# ---------------------------------------------------------------------------
echo
echo 'C. Runtime measurement -- the same run configuration, measured for real'
# ---------------------------------------------------------------------------
if docker run -d --name "$NAME" \
      --user 10001:10001 \
      --read-only \
      --cap-drop ALL \
      --security-opt no-new-privileges:true \
      --tmpfs /tmp:rw,noexec,nosuid,size=64m \
      --tmpfs /run:rw,noexec,nosuid,size=8m \
      --entrypoint /bin/sleep \
      "$IMAGE" 300 >/dev/null 2>&1; then

  insp() { docker inspect "$NAME" --format "$1" 2>/dev/null || echo '<none>'; }

  check 'read-only root filesystem enforced' 'true'  "$(insp '{{.HostConfig.ReadonlyRootfs}}')"
  check 'all capabilities dropped'           '[ALL]' "$(insp '{{.HostConfig.CapDrop}}' | tr -d ' ')"
  case "$(insp '{{range .HostConfig.SecurityOpt}}{{.}} {{end}}')" in
    *no-new-privileges*) pass 'no-new-privileges enforced' ;;
    *)                   fail 'no-new-privileges not enforced' ;;
  esac

  # Nothing from the host may appear. This is the whole point of the project.
  mounts="$(insp '{{range .Mounts}}{{.Source}} {{end}}')"
  case "$mounts" in
    *docker.sock*)   fail "a Docker socket is mounted: ${mounts}" ;;
    *)               pass 'no Docker socket mounted' ;;
  esac
  case "$mounts" in
    *"/home "*|*"/srv "*|*"/opt "*) fail "a host system path is mounted: ${mounts}" ;;
    *)                              pass 'no host system paths mounted' ;;
  esac
  case "$mounts" in
    *"/var/lib/docker"*) fail "the host Docker data directory is mounted: ${mounts}" ;;
    *)                   pass 'no host Docker data directory mounted' ;;
  esac
else
  fail 'could not start a container with the reference run configuration'
fi

# ---------------------------------------------------------------------------
echo
echo 'D. Refusals and absences (these MUST hold)'
# ---------------------------------------------------------------------------
must_refuse() { # must_refuse <description> <docker run args...>
  local desc="$1"; shift
  if docker run --rm "$@" >/dev/null 2>&1; then
    fail "${desc}"
  else
    pass "${desc}"
  fi
}

must_refuse 'refuses a non-loopback bind without PI_CAGE_ALLOW_PUBLIC' \
  "$IMAGE" serve --bind 0.0.0.0 --port 7681

must_refuse 'refuses a public bind with authentication disabled' \
  -e PI_CAGE_ALLOW_PUBLIC=1 -e PI_CAGE_AUTH_HEADER= \
  "$IMAGE" serve --bind 0.0.0.0 --port 7681

must_refuse 'refuses an unknown mode' "$IMAGE" definitely-not-a-mode

# A Docker client in the image is half of the host-escape pair (client + socket).
# We want neither half.
if docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'command -v docker' >/dev/null 2>&1; then
  fail 'the image contains a Docker client'
else
  pass 'no Docker client in the image'
fi

# ---------------------------------------------------------------------------
echo
if [ "$FAILED" = 0 ]; then
  echo 'All checks passed.'
else
  echo 'Some checks FAILED. Do not publish this image.' >&2
fi
exit "$FAILED"
