# Prior art: where `pi-cage` sits (survey, 2026-10-13)

This is a **map for positioning, not a gate**. Plenty of projects do parts of what
`pi-cage` does, several do them better, and that is useful: it tells you which
needs are already proven, which are not covered, and who is worth learning from.

If you are choosing a tool, read the alternatives — some will fit you better than
this one. If you are working on `pi-cage`, read the "what to borrow" rows.

> **Numbers are a single-day snapshot** from the GitHub API on 2026-10-13. Stars
> move; re-check before quoting any of this.

> ### Correction (2026-10-13)
>
> An earlier version of this file was wrong in three ways, all from one mistake:
> the survey used `sort=stars&per_page=25` and trusted a single broad query, so
> anything below the cutoff simply did not exist as far as the document was
> concerned.
>
> - It called [`jmfederico/pi-web`](https://github.com/jmfederico/pi-web) (874★)
>   "the incumbent". The real one is [`agegr/pi-web`](https://github.com/agegr/pi-web)
>   at **7,315★** — eight times larger, created two months earlier, and sitting at
>   about result #26 of the query, just past the cut.
> - It said nobody ships a hardened container. There are **a dozen** attempts,
>   including one 165★ project doing almost exactly this.
> - It missed everything above ~9,000 stars, including a 35,000★ Pi fork.
>
> The survey below uses six targeted queries, paginated, deduplicated: 460 matches
> filtered by layer. The lesson is in the method, not the conclusion — **a
> fixed-size top-N is not a survey.**

---

## The layers

Five layers, and they barely overlap. Most "which Pi project should I use"
confusion is really "which layer am I asking about".

### 1. Upstream and forks

| Project | ★ | License | What it is |
|---|---|---|---|
| [earendil-works/pi](https://github.com/earendil-works/pi) | 114,853 | MIT | The agent itself. No official image, no HTTP/server mode. |
| [can1357/oh-my-pi](https://github.com/can1357/oh-my-pi) | 35,352 | MIT | A full fork/rebrand (`@oh-my-pi/pi-coding-agent`, [omp.sh](https://omp.sh)), TypeScript + Rust, "the IDE wired in". |
| [badlogic/pi-skills](https://github.com/badlogic/pi-skills) | 2,606 | — | Skills from Pi's own author. |
| [huggingface/tau](https://github.com/huggingface/tau) | 2,957 | — | A Python port of Pi's agent loop. |
| [Dicklesworthstone/pi_agent_rust](https://github.com/Dicklesworthstone/pi_agent_rust) | 1,892 | — | A Rust reimplementation. |
| [MichaelKinsy/PiG](https://github.com/MichaelKinsy/PiG) | 591 | — | A Go port. |

Upstream's own position, from its security documentation: Pi has **no built-in
sandbox**, commands run with the permissions of the account that started it, and
isolation is something you supply with a container, VM or sandbox.

### 2. Desktops and web UIs — by far the most crowded

| Project | ★ | License | Note |
|---|---|---|---|
| [agegr/pi-web](https://github.com/agegr/pi-web) | **7,315** | MIT | The incumbent. Next.js, `npx @agegr/pi-web`, multilingual (en/zh-CN/zh-TW/ja/ru), browser demo, **built-in `PI_WEB_PASSWORD` auth** and `PI_WEB_ALLOWED_HOSTS`. |
| [vastsa/PI-Desktop](https://github.com/vastsa/PI-Desktop) | 6,799 | LGPL-3.0 | Electron + Rust desktop workspace. |
| [minghinmatthewlam/pi-gui](https://github.com/minghinmatthewlam/pi-gui) | 1,231 | — | Electron GUI. |
| [jmfederico/pi-web](https://github.com/jmfederico/pi-web) | 874 | MIT | Vite SPA + session daemon, multi-machine fleet, plugin API, and its own first-party `docker/` runtime. |
| [rcarmo/piclaw](https://github.com/rcarmo/piclaw) | 872 | — | "pi coding agent in a technicolor web trenchcoat". |
| [abcwyc/pi-agent-desktop](https://github.com/abcwyc/pi-agent-desktop) | 505 | — | Cross-platform desktop client. |
| [ygncode/pi-web](https://github.com/ygncode/pi-web) | 113 | MIT | "Drive your pi from any browser on your network". |
| [Epsilondelta-ai/pi-web](https://github.com/Epsilondelta-ai/pi-web) | 58 | MIT | A Go web UI. |

Both major web UIs state plainly that they are not a security boundary:

> **agegr**, closing a request for per-user isolated runtimes in two days:
> *"Pi and Pi Web are designed as local, single-user applications. A Pi Web process
> is not intended to provide a multi-tenant security boundary."*

> **jmfederico**, `docker/README.md`:
> *"It is not a sandbox, permission system, or multi-tenant platform. Do not expose
> it directly to the public internet without a trusted network, firewall, VPN, SSH
> tunnel, or authenticated reverse proxy."*

### 3. Isolation — the layer `pi-cage` competes in

| Project | ★ | License | Approach |
|---|---|---|---|
| [carderne/pi-sandbox](https://github.com/carderne/pi-sandbox) | 275 | MIT | **Tool-level**, on the host. A Pi extension; `bash` goes through an OS sandbox runtime (forked from Anthropic's) with allow/deny lists and interactive prompts. |
| **[cjermain/pi-less-yolo](https://github.com/cjermain/pi-less-yolo)** | **165** | Apache-2.0 | **The closest neighbour.** Isolated Docker container, Chainguard base, all capabilities dropped, `no-new-privileges`, project dir and `~/.pi/agent` mounted. A `mise` shim: `mise run pi`. |
| [gni/pi-coding-agent-container](https://github.com/gni/pi-coding-agent-container) | 56 | MIT | docker compose. |
| [mikeatlas/omp-sbx](https://github.com/mikeatlas/omp-sbx) | 35 | — | oh-my-pi inside Docker Sandboxes (`sbx`). |
| [cuolm/pi-sbx-llamacpp](https://github.com/cuolm/pi-sbx-llamacpp) | 31 | MIT | Docker Sandbox microVM + local llama-server. |
| [inoio/agents-sandbox](https://github.com/inoio/agents-sandbox) | 23 | — | One isolated environment per project, several agents including Pi. |
| [geut/sbx-shell-pi](https://github.com/geut/sbx-shell-pi) | 21 | — | Docker Sandboxes template image for Pi. |
| [pasky/pi-gondolin](https://github.com/pasky/pi-gondolin) | 19 | — | Pi extension: tools inside a Gondolin micro-VM. |
| [kcosr/pi-sandbox](https://github.com/kcosr/pi-sandbox) | 17 | — | "Policy-gated Pi distribution with managed execution backends". |
| [dotnaught/pi-omlx-sandbox](https://github.com/Dotnaught/pi-omlx-sandbox) | 18 | — | Docker Sandbox + oMLX model server. |
| [fkleon/pi-docker](https://github.com/fkleon/pi-docker) | 0 | MIT | Rootless Podman, five language variants. Careful work, no audience. |
| [valentinsavenko/pi-docker](https://github.com/valentinsavenko/pi-docker) | 0 | — | — |

`pi-less-yolo`'s honesty is worth copying outright:

> *"This is 'less YOLO', not 'no YOLO'. Container escapes exist. The mounted
> directories are fully writable. This is a meaningful reduction in risk, not a
> security guarantee."*

**The gap in this layer:** every one of these is a **local** tool — a wrapper around
your own Docker or a micro-VM on your workstation. **None ships a network egress
boundary, and none targets a cluster.** `pi-less-yolo` names exfiltration as a risk
and mitigates it with filesystem controls only.

### 4. Self-hosted service and job runners

| Project | ★ | License | Note |
|---|---|---|---|
| [spacering-net/codeg](https://github.com/spacering-net/codeg) | 3,942 | — | Collaborative multi-agent workspace aggregating several agents. |
| [HarnessRouter/harnessrouter](https://github.com/HarnessRouter/harnessrouter) | 2,995 | Apache-2.0 | Self-hosted unified interface for several agents. |
| [AltanS/collie](https://github.com/AltanS/collie) | 1,332 | — | Self-hosted PWA driving Claude Code, Pi and others. |
| [Ark0N/Codeman](https://github.com/Ark0N/Codeman) | 794 | — | Self-hosted mission control. |
| [open-mercato/cezar](https://github.com/open-mercato/cezar) | 663 | MIT | Orchestrator / ADE, "locally or 24/7 on your own server". |
| [useagenthq/useagent](https://github.com/useagenthq/useagent) | 384 | — | "Run Claude Code, Codex, OpenCode or Pi in isolated cloud". |
| [davidondrej/cloudroom-core](https://github.com/davidondrej/cloudroom-core) | 321 | — | Rust runtime running several agents "in the cloud". |
| **[edgehero/pi-dispatch](https://github.com/edgehero/pi-dispatch)** | **181** | MIT | **The closest neighbour on this axis.** Jobs from cron, CLI or forge events; each in a locked-down throwaway container; durable queue, spend caps, admin panel. |
| [pi-pod/pipod](https://github.com/pi-pod/pipod) | 161 | AGPL-3.0 | Control plane + sandbox service + Postgres + OIDC + mobile apps. Hosted tier planned. |
| [langgenius/mosoo](https://github.com/langgenius/mosoo) | 161 | — | Managed runtime for several agents including Pi. |

`pi-dispatch` states its scope as sharply as anyone:

> *"pi has no job queue, no concurrency control, no spend limit and, by its own
> README, no permission system. pi-dispatch adds exactly that layer and nothing
> else."*

**The gap in this layer:** all of them are Docker/Podman/Compose or a bespoke
control plane. **None delivers to Kubernetes**, and none has an egress boundary.

### 5. Extensions and directories

| Project | ★ | Note |
|---|---|---|
| [nicobailon/pi-web-access](https://github.com/nicobailon/pi-web-access) | 1,628 | Web search and fetch tools. |
| [nicobailon/pi-mcp-adapter](https://github.com/nicobailon/pi-mcp-adapter) | 1,591 | MCP adapter. |
| [qualisero/awesome-pi-agent](https://github.com/qualisero/awesome-pi-agent) | 1,099 | Awesome list. |
| [svkozak/pi-acp](https://github.com/svkozak/pi-acp) | 730 | ACP adapter. |
| [shaftoe/awesome-pi-coding-agent](https://github.com/shaftoe/awesome-pi-coding-agent) | 150 | Auto-curated directory. |

---

## What `pi-cage` claims — and what it does not

**Claims, and none of the projects above make them:**

| Claim | Evidence |
|---|---|
| Kubernetes delivery (manifests, no Docker socket required — which is also what makes it schedulable at all) | `deploy/k8s/` |
| An **egress network boundary**: default-deny, DNS + public TCP only, every internal range denied by destination address | `deploy/k8s/networkpolicy.yaml`, verified on a 6-node ARM64 Calico cluster, exit code 0 |
| Verifiers that **refuse to report a stale verdict** — preflight reads the cluster's own Pod/Service CIDRs and fails if the loaded policy does not cover them | `verify-network-boundary.sh` |
| ARM64 as a first-class, **hardware-verified** target | built and run on real ARM64 hardware |

**Does not claim:**

- To be the first, the only, or the best isolation for Pi. `pi-less-yolo` is ahead
  on local ergonomics and has a demonstrable isolation proof; `pi-sandbox` covers
  the host-tool layer; `pi-dispatch` covers job running and budgets.
- Any UI. Both `pi-web` projects are far ahead and neither is worth reimplementing.
- Published images, one-command install, spend caps, a job queue, or multi-tenancy.
- Any boundary at all on plain Docker. Compose has no egress primitive; that layer
  only exists on a CNI that implements NetworkPolicy.

## What to borrow

| From | Borrow |
|---|---|
| [`pi-less-yolo`](https://github.com/cjermain/pi-less-yolo) | A **demonstrable** isolation proof (their demo shows the agent failing to touch a file outside the mount); a minimal hardened base image; `mise`-style one-command ergonomics; Dependabot. |
| [`pi-dispatch`](https://github.com/edgehero/pi-dispatch) | Spend caps checked *before* anything is spent; a durable queue; multi-forge triggers; the discipline of adding one layer and saying so. |
| [`agegr/pi-web`](https://github.com/agegr/pi-web) | Multilingual docs; a **browser demo with no install**; shipping auth rather than deferring it; ADRs (`docs/adr/`). |
| [`jmfederico/pi-web`](https://github.com/jmfederico/pi-web) | A plugin API; machine federation; changesets; a **guard test that keeps docs scoped**. |
| Upstream | `--mode rpc` and `--mode json`, which `pi-cage` exposes but has never exercised. |

## Method

Six paginated queries against the GitHub search API (topics, `pi-web in:name`,
`pi coding agent`, `pi-mono`, `pi agent in:name`, and the isolation/server terms),
deduplicated to 460 repositories, filtered by layer, noise excluded. Star counts,
licences and dates from `api.github.com/repos/{owner}/{repo}` on 2026-10-13.

**Not covered by this survey:** anything without a discoverable GitHub presence,
projects named without the string "pi", and private or self-hosted deployments.
Absence from this table is not evidence of absence — which is exactly the mistake
the correction note at the top is about.
