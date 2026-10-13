# Threat model

> **Read this before exposing a `pi-cage` container to anyone or anything.**
>
> Pi's own security documentation says it plainly: commands run with the permissions of the account that started Pi, and Pi asks for approval only as often as you configure it to. `pi-cage` does not change that. It changes **what that account can reach**.

---

## 1. What we are protecting

| Asset | Why it matters |
|---|---|
| The host / node | If the container escapes, everything else on that machine is exposed |
| The cluster | The agent must not be able to reach the Kubernetes API, Vault, or other tenants' services |
| Cloud and provider metadata | `169.254.169.254` and friends hand out credentials |
| Model provider keys | Whoever reads them spends your money and can impersonate you |
| The operator's other systems | Reached over the network, or via git/ssh credentials placed in the container |
| The workspace itself | Contains whatever code and secrets you put there |

## 2. Adversaries considered

1. **Prompt injection from content the agent reads.** A README, an issue, a web page, a dependency's source. This is the realistic one: the agent is *designed* to read untrusted text and then act.
2. **A malicious dependency or Pi extension.** Pi extensions execute in-process with full access to the agent's filesystem and credentials.
3. **A hostile or careless API client.** Anything that can reach the served port and drive the agent.
4. **A compromised upstream artifact.** A changed package or base image.
5. **The agent making a mistake.** The most common case of all — a wrong `rm`, a wrong `git push`.

**Not considered:** a targeted attacker who already has code execution on the host or cluster. At that point the container is not your problem.

## 3. What is defended

| Control | Mechanism | Verify with |
|---|---|---|
| Container escape by capability | `cap_drop: [ALL]`, `no-new-privileges` | `docker inspect` → `HostConfig.CapDrop` |
| Escape by writable rootfs | `read_only: true`, tmpfs for `/tmp` and `/run` | `HostConfig.ReadonlyRootfs` |
| Host compromise via Docker | **No `/var/run/docker.sock` mount** — ever | `docker inspect` → `Mounts` |
| Host file access | No host path mounts. `pi-web` mounts `/home` `/srv` `/opt` read-write by design; `pi-cage` mounts none | `Mounts` |
| Host command execution | No `hostexec`-equivalent. The agent has only container-local `bash` | — |
| Cluster API access | No ServiceAccount token (`automountServiceAccountToken: false`), no kubeconfig, no RBAC | `kubectl exec … -- ls /var/run/secrets` |
| Metadata service | Egress NetworkPolicy excludes `169.254.0.0/16` | [NetworkPolicy](deploy/k8s/networkpolicy.yaml) |
| Lateral movement inside the cluster | `default-deny` + public-only egress; Pod/Service CIDRs excluded | same |
| Reaching the container | `default-deny` ingress; only explicitly labelled sources on the serve port | same |
| Silent access-control loss | `serve` refuses to bind publicly without an auth header or explicit opt-in; `build.sh` fails if `ttyd` lacks `--auth-header` / `--check-origin` | `pi-server serve --bind 0.0.0.0` should **fail** |
| Supply-chain drift | Base image pinned by digest, Pi pinned to an exact version, both written to `rendered/` | `rendered/` |
| Runaway resource use | Explicit requests/limits; no cluster has a default quota | manifests |

## 4. What is **not** defended

Be honest about the boundary. These are real, and some are unavoidable.

| Risk | Reality |
|---|---|
| **Prompt injection** | A container does not stop the agent from doing something harmful *inside* it. It bounds the blast radius to the container's workspace, credentials and network reach. That is the whole claim. |
| **Credentials inside the container** | Model keys and any git tokens you inject are readable by the agent and by any extension it loads. There is no way around this: the agent and its credentials share one uid. Only inject what you are willing to lose. |
| **Readable workspace** | Whatever you mount at `/workspace` is readable and writable by the agent. Mount the narrowest directory you can. |
| **Session transcripts** | Pi stores sessions as plain JSONL under the agent directory. They contain prompts, tool arguments and command output — **including anything the agent printed**. Back up and share accordingly. |
| **A compromised `ttyd` or proxy** | A terminal is a shell. A vulnerability in the web terminal or your authenticating proxy is a vulnerability in the shell. |
| **Kernel or runtime escape** | `pi-cage` uses ordinary containers. It is not a VM. `gVisor`, Kata, `microsandbox` and friends give a stronger boundary; `pi-cage` interoperates with them but does not provide one. |
| **Multi-tenancy** | Do not run one `pi-cage` for several mutually distrusting users. One container = one trust domain. |
| **Network egress by default is broad** | The egress policy allows the public internet so that package managers and git work. Public egress means exfiltration is possible. Narrow it if your workflow allows. |
| **IPv6** | The NetworkPolicy `ipBlock` rules are IPv4 only. Confirm your node has no IPv6 egress, or add rules. |
| **Denial of service** | Nothing stops the agent from consuming its CPU/memory limit and being OOM-killed. |

## 5. Explicit non-goals

- Protecting you from an agent you asked to do something destructive.
- Protecting the workspace from the agent. The agent is *supposed* to write there.
- Being a substitute for reviewing what the agent did.

## 6. Deployment preconditions

Before letting this container talk to anything you care about:

- [ ] `docker inspect` shows no `docker.sock` and no host path mounts (Compose file reviewed line by line).
- [ ] The serve port is **not** reachable from the public internet without an authenticating proxy in front.
- [ ] The proxy is the only path in, and its header is the only thing `serve` trusts.
- [ ] Egress from inside the container cannot reach the Kubernetes API, your internal services, or `169.254.169.254` — test from **inside the real container**, not from a throwaway probe.
- [ ] Only the credentials you accept losing are mounted or injected.
- [ ] The workspace mount is the narrowest directory that works.
- [ ] A backup exists and is encrypted (the agent directory holds credentials).

## 7. Reporting

See [SECURITY.md](SECURITY.md). Do not open a public issue for a security report.
