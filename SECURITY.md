# Security policy

## Reporting a vulnerability

**Do not open a public issue for a security report.**

Use GitHub's private vulnerability reporting on this repository (Security → Report a vulnerability). If that is unavailable, open a minimal public issue asking for a private channel — without details.

Please include: affected version or commit, what you did, what happened, and what you expected. A proof of concept helps enormously.

Expect an acknowledgement within about a week. This is a small project maintained in spare time; that is the honest turnaround, not a promise of faster.

## Scope

**In scope**

- Container escape from a `pi-cage` container to its host or node.
- Reaching an asset the [threat model](THREAT-MODEL.md) claims is defended: the Docker socket, host paths, the Kubernetes API, cloud metadata, or other tenants.
- A default that silently removes an access control — for example `serve` binding publicly without authentication, or `build.sh` succeeding with a base image of the wrong architecture.
- Supply-chain weaknesses in `build.sh` or the Dockerfile: unpinned or unverified inputs, digest confusion.

**Out of scope**

- Anything Pi itself does. The agent executing commands, reading files, and following instructions is its documented design, not a `pi-cage` vulnerability. Report those upstream.
- Prompt injection. A container bounds the blast radius; it does not prevent the injected action. See [THREAT-MODEL.md](THREAT-MODEL.md) §4.
- An operator who mounts the Docker socket, a host path, or a credential they did not want the agent to read. The project's position is that the container is the boundary — defeating it is configuration, not a bug worth a CVE.
- Denial of service against your own container by your own agent.

## What this project will not do

- Add a Docker socket mount, a host path mount, or a host-execution escape hatch. If you need those, use [`pi-web`](https://github.com/jmfederico/pi-web), which does them well and on purpose.
- Add multi-tenancy. One container, one trust domain.
