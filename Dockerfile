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
RUN set -eux; \
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
ARG TTYD_VERSION=1.7.7
ARG TTYD_SHA256_ARM64=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165
ARG TTYD_SHA256_AMD64=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        arm64) asset="ttyd.aarch64"; want="${TTYD_SHA256_ARM64}" ;; \
        amd64) asset="ttyd.x86_64";  want="${TTYD_SHA256_AMD64}" ;; \
        *) echo "pi-cage: no ttyd asset mapped for architecture ${arch}" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/${asset}"; \
    curl -fsSL --retry 3 --retry-delay 2 -o /usr/local/bin/ttyd "${url}"; \
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
