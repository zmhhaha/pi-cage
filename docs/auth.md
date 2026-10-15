# Authentication

`serve` exposes a **shell**. Everything below is about making sure only the people
you meant can reach it, and about being honest regarding how much of that is
enforced by the container itself — the answer is: less than you would like.

## What `serve` does

| Behaviour | Detail |
|---|---|
| Default bind | `127.0.0.1`. It refuses anything else without `PI_CAGE_ALLOW_PUBLIC=1`. |
| Non-loopback bind | Refused **unless** an auth header is configured. Binding `0.0.0.0` with authentication turned off is not possible. |
| `PI_CAGE_AUTH_HEADER` | Defaults to `X-Auth-Request-Email`. Read with `-`, not `:-`, so **unset means required** and only an explicit empty value (`PI_CAGE_AUTH_HEADER=`) disables it. |
| Header check | Performed by `ttyd` on **every** request, including the WebSocket upgrade. A request without it gets `407 Proxy Auth Required`. |

Both refusals are covered by [`verify-hardening.sh`](../verify-hardening.sh), which
fails if they stop holding.

## The header is a bearer token, not an identity

Measured against a running `serve` with `PI_CAGE_AUTH_HEADER=X-Auth-Request-Email`:

| Request | Result |
|---|---|
| no header | `407` |
| `X-Auth-Request-Email: someone@example.com` | `200` |
| `X-Auth-Request-Email: x` | `200` |
| `X-Auth-Request-Email:` (empty) | `407` |
| `X-Auth-Request-Email: $(id)` | `200` |

**`ttyd` checks presence and non-emptiness. It does not check the value, and it
does not verify any signature.** Anything that can open a connection to the port
and set that header is in, regardless of what it writes there.

So the security of a deployment rests entirely on two things outside the container:

1. **who can reach the port** — a NetworkPolicy, a firewall, or a private network;
2. **who sets the header** — one authenticating proxy, and nothing else.

This is why the [THREAT-MODEL](../THREAT-MODEL.md) calls the container a boundary
and not a multi-tenant platform, and why `deploy/k8s/` ships a default-deny policy
rather than relying on the header alone.

## The three settings that decide whether it works

Taken from a working `oauth2-proxy` deployment running in production on the same
cluster this project was verified against. Each of these fails *quietly* — the
login succeeds and the terminal still does not work.

| Setting | Why |
|---|---|
| `set_xauthrequest = true` | **Without it, `oauth2-proxy` does not emit `X-Auth-Request-Email` at all.** It sets `X-Forwarded-*`, which is not what `serve` reads. Every request gets `407` after a successful login. This is the single most common reason an otherwise correct OIDC setup fails. |
| `proxy_websockets = true` | `ttyd` is a WebSocket terminal. Without this the page loads and the terminal never connects. |
| `upstreams = ["http://127.0.0.1:7681/"]` | The proxy must share the network namespace with `serve` if you want to keep the loopback bind. Different namespace means the cage has to bind `0.0.0.0`. |

## Two settings that stop `oauth2-proxy` from starting at all

Both were hit while testing this, and both produce a clear one-line error:

```
invalid configuration: cookie_secret must be 16, 24, or 32 bytes to create an
AES cipher, but is 64 bytes

invalid configuration: missing setting for email validation: email-domain or
authenticated-emails-file required.
    use email-domain=* to authorize all email addresses
```

`cookie_secret` must be **exactly 16, 24 or 32 bytes**. An email allow-list —
`email_domains` or `authenticated_emails_file` — is **mandatory**, not optional.

## The failure that names the wrong thing entirely

Worth its own section, because the error message sends you somewhere else.

`oauth2-proxy` stores the session in a cookie by default. If the IdP issues large
tokens — Casdoor's `id_token` and `access_token` are JWTs with a full claim set —
the session can exceed the browser's 4 KB per-cookie limit, and oauth2-proxy says
so at the moment it creates one:

```
[session_store.go:170] WARNING: Multiple cookies are required for this session as
it exceeds the 4kb cookie limit. Please use server side session storage
(eg. Redis) instead.
```

The consequence is not a clean failure. The session comes back **partially
restored**: enough for oauth2-proxy to consider the request authenticated and
forward it, but not enough to recover the email claim that
`set_xauthrequest` needs to set `X-Auth-Request-Email`. `serve` then receives a
request with no header and answers:

```
HTTP/1.1 407 Proxy Auth Required
Proxy-Authenticate: Basic realm="ttyd"
```

**A browser reads a `407` as a proxy problem**, so the user sees
`ERR_UNEXPECTED_PROXY_AUTH` — "the proxy requires authentication" — for what is
actually a session-size problem, on a proxy that is running correctly and on an
account that has already logged in successfully. The oauth2-proxy log shows
`AuthSuccess` immediately before it.

Two ways out, and they are not equivalent:

| Fix | Effect | Cost |
|---|---|---|
| `session_cookie_minimal = true` | Strips the tokens from the cookie, keeps the identity claims — which is all `set_xauthrequest` reads | **Cannot be combined with `cookie_refresh`**; oauth2-proxy refuses to start. The session then lasts `cookie_expire` and asks for a fresh login instead of renewing. |
| `session_store_type = "redis"` + `redis_connection_url` | Removes the size limit entirely, keeps refresh | A Redis to run, secure and keep available |

The conflict is real and oauth2-proxy states it plainly:

```
invalid configuration:
  cookie_refresh > 0 requires oauth tokens in sessions.
  session_cookie_minimal cannot be set
```

**A note on disabling refresh deliberately.** A refresh that cannot succeed is
worse than no refresh: an oauth2-proxy holding a session whose refresh token has
been revoked retries that refresh on **every request** and never gives up. On the
cluster this was measured on, one such session produced roughly **98 token
requests per second** against the IdP's `/api/login/oauth`, exhausted the IdP's
database connections, and took login down for **every** service behind it —
surfacing as `Error 1040: Too many connections` on an unrelated page. A session
that cannot refresh cannot loop.

## Moving the session server-side

If the cookie is the problem, the durable fix is to stop keeping the session in
it. `oauth2-proxy` supports Redis, and there are **two places the setting can
live** — which matters more than it sounds:

```
# in the config file
session_store_type = "redis"
redis_connection_url = "redis://:redis-password@redis:6379/6"

# or as flags, which the config file cannot do for a value that comes from a Secret
args:
  - --config=/oauth/oauth2-proxy.cfg
  - --session-store-type=redis
  - --redis-connection-url=redis://:$(REDIS_PASSWORD)@redis:6379/6
```

**`$(REDIS_PASSWORD)` is Kubernetes' own substitution, not shell.** Kubernetes
expands `$(VAR)` inside `command`, `args` and `env` from the container's
environment, so a password delivered by `envFrom: secretRef` can be spliced into a
URL without the manifest ever containing it. This is verified working rather than
assumed: with the expansion in place the proxy logs no Redis errors, and sessions
appear in the target database with the expected TTL. It does **not** work inside a
mounted config file — only in the fields Kubernetes itself expands.

**A note on reviewing this later, because it cost real time here.** A config-file
setting and a flag produce identical runtime behaviour, so a check that reads only
one of them can report "not configured" about a deployment that is configured.
Reading the config file, the `env` list and `envFrom` is not enough; `args` is
where this kind of value usually ends up. That mistake was made — twice — while
reviewing a working deployment.

### What you take on

Cookie sessions have **no server-side dependency**: a proxy that restarts loses
nothing, and nothing else has to be up for a login to complete. Redis removes
that property:

| | Cookie session | Redis session |
|---|---|---|
| Session size limit | 4 KB per cookie | none |
| Refresh loops possible | yes, unless refresh is off | yes, unless refresh is off |
| Login depends on | the IdP only | **the IdP and Redis** |
| Proxy restart | sessions survive (client holds them) | sessions survive (Redis holds them) |
| Redis restart | irrelevant | sessions survive if persistence is on |

**Redis becomes an availability dependency for every login behind it.** If it is
unreachable, `oauth2-proxy` cannot store a session, so a user who authenticates
correctly still does not get in — which is worse than the cookie limit it solves.
Before adopting it, check that the Redis is:

- **persistent** (`appendonly yes` — otherwise every restart logs everyone out),
- **not evicting** under its memory policy — `allkeys-lru` will drop session keys
  and log users out when the instance fills up, which is survivable but should be
  a decision rather than a surprise,
- **not a single point of failure** if the services behind it matter.

Give each service its **own database or key prefix**. Sharing a database is not an
exploit — the session payload is encrypted with that service's own `cookie_secret`,
so a cross-read fails to decrypt — but it is untidy and it invites the question.

---

## Recipe 1 — `oauth2-proxy` as a sidecar (recommended)

This is the shape the project was designed around, and it is the only one that
keeps `serve` on its loopback default.

Two things about the shipped `networkpolicy.yaml` matter here, and both were read
off the live cluster rather than assumed:

- **`public-egress` selects `role: cage`.** So the sidecar must carry that label,
  or it cannot reach the OIDC issuer at all. With the label it inherits the same
  public-TCP egress the cage has, which is exactly what OIDC discovery needs.
- **`proxy-ingress` admits only `port: 7681` on `role: cage` pods.** The sidecar
  listens on `4180`, which is therefore **not reachable** without an additional
  rule. This is the one change the sidecar shape requires.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pi-cage-oauth
  namespace: pi-cage
data:
  emails: |
    you@example.com
  oauth2-proxy.cfg: |
    http_address = "0.0.0.0:4180"
    provider = "oidc"
    oidc_issuer_url = "https://your-idp.example.com"
    redirect_url = "https://pi-cage.example.com/oauth2/callback"
    upstreams = ["http://127.0.0.1:7681/"]
    # Without this, no X-Auth-Request-Email is sent and serve answers 407 for ever.
    set_xauthrequest = true
    # ttyd is a websocket; without this the terminal never loads.
    proxy_websockets = true
    # Exactly 16, 24 or 32 bytes. 32 random bytes, base64 or raw.
    cookie_secret = "<32 bytes>"
    cookie_name = "__Host-pi-cage"
    cookie_secure = true
    cookie_samesite = "lax"
    # Mandatory. One of these two, not neither.
    authenticated_emails_file = "/oauth/emails"
    pass_host_header = true
    reverse_proxy = true
    skip_provider_button = true
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pi-cage
  namespace: pi-cage
spec:
  replicas: 1
  selector:
    matchLabels: { app: pi-cage }
  template:
    metadata:
      labels:
        app: pi-cage
        # Required: public-egress selects on this label, and the sidecar needs
        # egress to the OIDC issuer.
        role: cage
    spec:
      containers:
        - name: pi-cage
          image: ghcr.io/zmhhaha/pi-cage:latest
          args: ["serve"]
          env:
            # No PI_CAGE_BIND and no PI_CAGE_ALLOW_PUBLIC: the loopback default
            # is kept, and the sidecar reaches it over 127.0.0.1 in this netns.
            - name: PI_CAGE_AUTH_HEADER
              value: X-Auth-Request-Email
          # ... securityContext, resources, probes and volumes as in deploy/k8s/core.yaml
        - name: oauth2-proxy
          image: quay.io/oauth2-proxy/oauth2-proxy:v7.8.0
          args: ["--config=/oauth/oauth2-proxy.cfg"]
          ports:
            - name: http
              containerPort: 4180
          volumeMounts:
            - { name: oauth, mountPath: /oauth }
          readinessProbe:
            httpGet: { path: /ping, port: 4180 }
      volumes:
        - name: oauth
          configMap: { name: pi-cage-oauth }
```

The Service must target the **proxy**, not the cage:

```yaml
  ports:
    - name: http
      port: 4180
      targetPort: http # the oauth2-proxy container
```

And `networkpolicy.yaml` needs the proxy port admitted from wherever your ingress
lives. Without this rule the sidecar is up, healthy, and unreachable:

```yaml
  ingress:
    - from:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              pi-cage-client: "true"
      ports:
        - port: 7681 # the cage, for the separate-proxy shape
          protocol: TCP
        - port: 4180 # the sidecar
          protocol: TCP
```

## Recipe 2 — a separate proxy pod

Simpler manifest, and it costs the loopback bind: the cage must set
`PI_CAGE_BIND=0.0.0.0` and `PI_CAGE_ALLOW_PUBLIC=1`, which is what
[`deploy/k8s/core.yaml`](../deploy/k8s/core.yaml) ships by default. Everything else
is the same config.

The proxy pod needs the `pi-cage-client: "true"` label to be admitted by
`proxy-ingress`.

**Watch the namespace.** If the proxy runs in the same namespace as the cage,
`default-deny` denies *its* egress too, so it cannot reach the OIDC issuer unless
you give it a rule. If it runs in a namespace with permissive egress — which is the
usual arrangement for an ingress controller — this does not arise. Both cases were
hit while testing:

```
[provider.go:55] Performing OIDC Discovery...     # and then: nothing, ever
```

## Recipe 3 — no IdP: any authenticating reverse proxy

If you do not run an identity provider, all you need is something that
authenticates and then sets the header. Any value will do; `ttyd` only checks that
it is present and non-empty.

**Caddy**, with a self-contained password file:

```caddyfile
pi-cage.example.com {
    basic_auth {
        you $2a$14$<bcrypt hash from: caddy hash-password>
    }
    reverse_proxy 127.0.0.1:7681 {
        header_up X-Auth-Request-Email {http.auth.user.id}
    }
}
```

**nginx**, if you already have one:

```nginx
location / {
    auth_basic           "pi-cage";
    auth_basic_user_file /etc/nginx/.htpasswd;

    proxy_pass           http://127.0.0.1:7681;
    proxy_set_header     X-Auth-Request-Email $remote_user;
    proxy_http_version   1.1;
    # ttyd is a websocket. All three of these are required.
    proxy_set_header     Upgrade    $http_upgrade;
    proxy_set_header     Connection "upgrade";
    proxy_read_timeout   3600s;
}
```

Both examples assume the proxy shares a network namespace with `serve`; otherwise
use the `0.0.0.0` bind from Recipe 2 and point at the Service instead of
`127.0.0.1`.

---

## What was tested, and what was not

| Claim | Status |
|---|---|
| `ttyd` rejects a request with no header, and with an empty one | **Tested.** `407` in both cases. |
| `ttyd` accepts any non-empty value, including `x` and `$(id)` | **Tested.** `200`. |
| The two startup refusals in `serve` (non-loopback without opt-in; non-loopback with auth off) | **Tested**, and asserted by `verify-hardening.sh`. |
| `oauth2-proxy` refuses to start on a 64-byte `cookie_secret` | **Tested** on the cluster this project was verified against. |
| `oauth2-proxy` refuses to start without an email allow-list | **Tested**, same cluster. |
| That `public-egress` admits only `role: cage`, and that a sidecar without that label cannot reach the IdP | **Observed**: the pod reached `Performing OIDC Discovery...` and never progressed. The policy selectors quoted above were read from the live cluster. |
| That `proxy-ingress` admits only port 7681, so a sidecar on 4180 is unreachable | **Read from the live policy.** Not exercised end to end. |
| The sidecar manifest in Recipe 1 | **Applied and running** on a real cluster, `2/2`, with the loopback property asserted (both address families). The full browser login through it is still unverified. |
| A complete login in a browser, through to a working terminal | **Never done.** The header mechanics are tested; the OIDC round trip and the WebSocket upgrade through a real proxy are not. |
| `set_xauthrequest` and `proxy_websockets` being required | **From a working production configuration**, not from a failure reproduced here. |
| The session exceeding the 4 KB cookie limit, and the `407`/`ERR_UNEXPECTED_PROXY_AUTH` it produces | **Observed**: oauth2-proxy logged the warning itself, immediately after an `AuthSuccess` for the same session, and `serve` answers `407` to a request without the header. |
| `$(REDIS_PASSWORD)` in `args` being expanded by Kubernetes | **Verified in production**: the proxy logs no Redis errors and sessions appear in the target database with the expected TTL. |
| That a Redis outage would block logins | **Not tested.** Follows from oauth2-proxy needing to store the session, and is the reason the trade-off table above exists. |
