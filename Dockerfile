# syntax=docker/dockerfile:1
#
# pi-cage — an isolation-first container for the Pi coding agent.
#
# Design rule for this file: nothing here may add host access. No Docker socket,
# no host path mounts, no host-execution helper. If you need those, you want
# pi-web (https://github.com/jmfederico/pi-web), not this project.

ARG NODE_IMAGE=node:24-bookworm-slim
FROM ${NODE_IMAGE}

ARG PI_PACKAGE=@earendil-works/pi-coding-agent@0.99.2
ARG NPM_REGISTRY=https://registry.npmjs.org

# --- runtime tooling --------------------------------------------------------
# APT_MIRROR exists for the same reason this ecosystem carries NPM_REGISTRY and
# PIP_INDEX_URL overrides: deb.debian.org is slow or unreachable from some
# networks. Measured on a Tencent Cloud VPS in mainland China -- this exact step
# stalled for 19 minutes with one open connection and a load average of 0.18,
# while mirrors.cloud.tencent.com answered both suites instantly.
#
#   docker build --build-arg APT_MIRROR=http://mirrors.cloud.tencent.com ...
#
# Empty (the default) leaves the base image's own sources untouched. The mirror
# must serve both the `debian` and `debian-security` suites.
ARG APT_MIRROR=
RUN set -eux; \
    if [ -n "${APT_MIRROR}" ]; then \
      for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources; do \
        [ -f "$f" ] && sed -i "s|http://deb.debian.org|${APT_MIRROR}|g" "$f"; \
      done; \
      echo 'effective apt sources:'; \
      grep -rhE '^(URIs|deb) ' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | head -4 || true; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        fd-find \
        git \
        openssh-client \
        passwd \
        ripgrep \
        tini \
        tmux; \
    rm -rf /var/lib/apt/lists/*; \
    # Pi's `find` tool shells out to `fd`. Without it Pi prints
    # "fd not found. Downloading..." and fetches a binary AT RUNTIME -- a network
    # dependency and a supply-chain hole in an image whose entire premise is
    # being pinned and reproducible. Observed on a real cluster, 2026-10-13.
    #
    # Debian's fd-find package installs the binary as `fdfind` (the name `fd`
    # collides with another package), so symlink the name Pi looks for. Resolve
    # the path instead of hard-coding it, and prove the result works here.
    fdfind_path="$(command -v fdfind || true)"; \
    [ -n "${fdfind_path}" ] || { echo 'fd-find installed but fdfind is not on PATH' >&2; exit 1; }; \
    ln -s "${fdfind_path}" /usr/local/bin/fd; \
    fd --version

# --- ttyd (web terminal for `serve`) ----------------------------------------
# Deliberately NOT from apt:
#   * Debian bookworm has no ttyd package at all. The first real build
#     (2026-10-13) failed with "Package 'ttyd' has no installation candidate";
#     it only appears in later Debian suites.
#   * Distribution builds lag on the flags `serve` needs, and a missing
#     --auth-header or --check-origin removes an access control instead of
#     breaking loudly.
#
# So: upstream static release, PINNED BY DIGEST rather than by tag. Fetching the
# release's own SHA256SUMS from the same origin would only catch corruption, not
# tampering -- the digests below are the actual pin. They are transcribed from
# https://github.com/tsl0922/ttyd/releases/download/1.7.7/SHA256SUMS
# Update TTYD_VERSION and both digests together, never separately.
#
# TTYD_BASE_URL exists because github.com release downloads are unreliable or
# outright unreachable on some networks (measured: a Tencent Cloud VPS in
# mainland China times out on github.com entirely while codeload.github.com
# works). Override it to point at a mirror, an internal artifact store, or a
# local directory -- `file:///path` works, with the file at
# ${TTYD_BASE_URL}/${TTYD_VERSION}/${asset}.
#
# The SHA-256 check runs regardless of where the bytes came from, so changing the
# source cannot weaken the pin. The pin is the digest, not the URL.
ARG TTYD_VERSION=1.7.7
ARG TTYD_SHA256_ARM64=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165
ARG TTYD_SHA256_AMD64=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
ARG TTYD_BASE_URL=https://github.com/tsl0922/ttyd/releases/download
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        arm64) asset="ttyd.aarch64"; want="${TTYD_SHA256_ARM64}" ;; \
        amd64) asset="ttyd.x86_64";  want="${TTYD_SHA256_AMD64}" ;; \
        *) echo "pi-cage: no ttyd asset mapped for architecture ${arch}" >&2; exit 1 ;; \
    esac; \
    url="${TTYD_BASE_URL}/${TTYD_VERSION}/${asset}"; \
    curl -fsSL --retry 3 --retry-delay 2 -o /usr/local/bin/ttyd "${url}" \
      || { echo "pi-cage: could not fetch ${url}" >&2; \
           echo "  If github.com is unreachable here, override TTYD_BASE_URL with a" >&2; \
           echo "  mirror or a local path; the SHA-256 check below still applies." >&2; \
           exit 1; }; \
    echo "${want}  /usr/local/bin/ttyd" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/ttyd; \
    ttyd --version

# --- Pi coding agent (exact version, no lifecycle scripts) ------------------
# build.sh refuses to pass anything but an exact version. Pi needs no install
# scripts for a normal npm install; skipping them removes a whole class of
# build-time supply-chain surprise.
RUN set -eux; \
    NPM_CONFIG_REGISTRY="${NPM_REGISTRY}" npm install -g --ignore-scripts "${PI_PACKAGE}"; \
    npm cache clean --force; \
    rm -rf /root/.npm

# --- build-time gates -------------------------------------------------------
COPY docker/assert-image.sh /usr/local/lib/pi-cage/assert-image.sh
RUN set -eux; \
    chmod 0755 /usr/local/lib/pi-cage/assert-image.sh; \
    /usr/local/lib/pi-cage/assert-image.sh

# --- unprivileged runtime user ---------------------------------------------
ARG PI_UID=10001
ARG PI_GID=10001
RUN set -eux; \
    groupadd --gid "${PI_GID}" pi; \
    useradd --uid "${PI_UID}" --gid "${PI_GID}" \
            --create-home --home-dir /home/pi --shell /bin/bash pi

COPY pi-server /usr/local/bin/pi-server
RUN chmod 0755 /usr/local/bin/pi-server

ENV HOME=/home/pi \
    PI_CODING_AGENT_DIR=/home/pi/.pi/agent \
    PI_SKIP_VERSION_CHECK=1 \
    LANG=C.UTF-8 \
    TZ=UTC

WORKDIR /workspace
USER 10001:10001

# Documented for humans; the operator chooses what to publish. See README.
EXPOSE 7681

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/pi-server"]
CMD ["serve"]
