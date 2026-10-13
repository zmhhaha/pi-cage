#!/usr/bin/env bash
#
# Build pi-cage. Fails closed: a build that cannot prove its inputs is worse
# than no build at all.
#
#   ./build.sh                 current architecture, local image
#   ./build.sh --multiarch     linux/amd64 + linux/arm64 via buildx, pushes
#   ./build.sh --push          build and push the single-arch image
#   ./build.sh --dry-run       print the plan, touch nothing
#
# Overrides go in build.local.env (gitignored), never in this file.

set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

DRY_RUN=0
MULTIARCH=0
PUSH=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=1 ;;
    --multiarch) MULTIARCH=1; PUSH=1 ;;
    --push)     PUSH=1 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

# shellcheck disable=SC1091
[ -f build.local.env ] && . ./build.local.env

NODE_IMAGE="${NODE_IMAGE:-node:24-bookworm-slim}"
PI_PACKAGE="${PI_PACKAGE:-@earendil-works/pi-coding-agent@0.99.2}"
IMAGE="${IMAGE:-pi-cage}"
REGISTRY="${REGISTRY:-}"
TAG="${TAG:-$(date -u +%Y%m%dT%H%M%SZ)}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"

host_arch() { uname -m | sed 's/^x86_64$/amd64/; s/^aarch64$/arm64/'; }
PLATFORM="${PLATFORM:-linux/$(host_arch)}"

die() { printf 'build: error: %s\n' "$*" >&2; exit 1; }
run() { printf '+ %s\n' "$*" >&2; [ "$DRY_RUN" = 1 ] || "$@"; }

command -v docker >/dev/null 2>&1 || die 'docker is required'

# --- input validation -------------------------------------------------------
# Pi must be pinned to an exact version. `latest` would let a rebuild change the
# CLI contract under a running deployment.
case "$PI_PACKAGE" in
  @earendil-works/pi-coding-agent@[0-9]*.[0-9]*.[0-9]*) ;;
  *) die "PI_PACKAGE must be @earendil-works/pi-coding-agent@<exact version>, got: ${PI_PACKAGE}" ;;
esac
case "$PI_PACKAGE" in
  *@latest|*@next|*@alpha|*@beta) die "PI_PACKAGE must be an exact version, got: ${PI_PACKAGE}" ;;
esac

if [ -n "$REGISTRY" ]; then
  IMAGE_REF="${REGISTRY%/}/${IMAGE}"
else
  IMAGE_REF="${IMAGE}"
fi

build_args=(
  --build-arg "NODE_IMAGE=${NODE_IMAGE_RESOLVED:-$NODE_IMAGE}"
  --build-arg "PI_PACKAGE=${PI_PACKAGE}"
  --build-arg "NPM_REGISTRY=${NPM_REGISTRY}"
)

if [ "$MULTIARCH" = 1 ]; then
  # ---------------------------------------------------------------------
  # Multi-arch path. A per-platform digest would break the other platform, so
  # pin the manifest LIST digest instead.
  # ---------------------------------------------------------------------
  command -v docker >/dev/null
  docker buildx version >/dev/null 2>&1 || die 'docker buildx is required for --multiarch'

  if [ "$DRY_RUN" = 0 ]; then
    INDEX_DIGEST="$(docker buildx imagetools inspect "$NODE_IMAGE" --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
    [ -n "$INDEX_DIGEST" ] || die "could not resolve a manifest-list digest for ${NODE_IMAGE}; refusing to build multi-arch from a mutable tag"
    NODE_IMAGE_RESOLVED="${NODE_IMAGE%%:*}@${INDEX_DIGEST}"
    printf 'base image pinned to manifest list: %s\n' "$NODE_IMAGE_RESOLVED" >&2
  else
    NODE_IMAGE_RESOLVED="$NODE_IMAGE"
  fi

  build_args=(
    --build-arg "NODE_IMAGE=${NODE_IMAGE_RESOLVED}"
    --build-arg "PI_PACKAGE=${PI_PACKAGE}"
    --build-arg "NPM_REGISTRY=${NPM_REGISTRY}"
  )

  target="${IMAGE_REF}:${TAG}"
  run docker buildx build \
    --platform linux/amd64,linux/arm64 \
    "${build_args[@]}" \
    --tag "$target" \
    --tag "${IMAGE_REF}:latest" \
    --push \
    .

  if [ "$DRY_RUN" = 0 ]; then
    mkdir -p rendered
    printf '%s\n' "$target" > rendered/image.txt
    printf '%s\n' "$NODE_IMAGE_RESOLVED" > rendered/base-image.txt
    printf '%s\n' "$PI_PACKAGE" > rendered/pi-package.txt
    printf 'linux/amd64,linux/arm64\n' > rendered/platforms.txt
  fi

  echo 'Multi-arch build complete:' >&2
  echo "  ${target}" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Single-arch path: resolve the base to a digest and build only from that.
# ---------------------------------------------------------------------------
expected_arch="${PLATFORM##*/}"

run docker pull --platform "$PLATFORM" "$NODE_IMAGE"

if [ "$DRY_RUN" = 0 ]; then
  actual_arch="$(docker image inspect "$NODE_IMAGE" --format '{{.Architecture}}')"
  [ "$actual_arch" = "$expected_arch" ] || die "base image architecture is ${actual_arch}, expected ${expected_arch}"

  NODE_IMAGE_RESOLVED="$(docker image inspect "$NODE_IMAGE" --format '{{index .RepoDigests 0}}')"
  case "$NODE_IMAGE_RESOLVED" in
    *@sha256:*) ;;
    *) die "could not resolve a digest for ${NODE_IMAGE}" ;;
  esac
  printf 'base image pinned to digest: %s\n' "$NODE_IMAGE_RESOLVED" >&2

  build_args=(
    --build-arg "NODE_IMAGE=${NODE_IMAGE_RESOLVED}"
    --build-arg "PI_PACKAGE=${PI_PACKAGE}"
    --build-arg "NPM_REGISTRY=${NPM_REGISTRY}"
  )
else
  NODE_IMAGE_RESOLVED="$NODE_IMAGE"
fi

target="${IMAGE_REF}:${TAG}"
run docker build \
  --platform "$PLATFORM" \
  "${build_args[@]}" \
  --tag "$target" \
  --tag "${IMAGE_REF}:latest" \
  .

if [ "$PUSH" = 1 ]; then
  run docker push "$target"
  run docker push "${IMAGE_REF}:latest"
fi

if [ "$DRY_RUN" = 0 ]; then
  mkdir -p rendered
  docker image inspect "$target" --format '{{index .RepoDigests 0}}' > rendered/image.txt 2>/dev/null \
    || printf '%s\n' "$target" > rendered/image.txt
  printf '%s\n' "$NODE_IMAGE_RESOLVED" > rendered/base-image.txt
  printf '%s\n' "$PI_PACKAGE" > rendered/pi-package.txt
  printf '%s\n' "$PLATFORM" > rendered/platforms.txt
  echo 'Build complete.' >&2
  cat rendered/image.txt >&2
fi

if [ "$PUSH" = 0 ] && [ "$DRY_RUN" = 0 ]; then
  cat >&2 <<EOF

Not pushed (no --push). To record reproducible evidence for a release:

  ./verify-hardening.sh ${target}
EOF
fi
