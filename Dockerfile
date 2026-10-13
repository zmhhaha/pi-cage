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
# ttyd serves `serve` mode. Debian's build has historically lagged upstream, so
# assert-image.sh below fails the build if a flag we depend on is missing --
# a silently absent --auth-header or --check-origin would remove an access
# control rather than break loudly.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        openssh-client \
        passwd \
        ripgrep \
        tini \
        tmux \
        ttyd; \
    rm -rf /var/lib/apt/lists/*

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
