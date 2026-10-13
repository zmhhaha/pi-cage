#!/usr/bin/env bash
#
# pi-cage network boundary verification.
#
#   Usage: bash verify-network-boundary.sh [options]
#
#     --namespace <ns>        namespace to verify        (default pi-cage)
#     --deploy <name>         deployment to verify       (default pi-cage)
#     --container <name>      container to exec into     (default pi-cage)
#     --also-blocked <h:p>    extra target that MUST be refused (repeatable)
#     --also-reachable <h:p>  extra target that should be reachable (repeatable)
#     --no-outsider           skip section 5 (it creates a one-shot Pod)
#     --explain               print the expectation table and exit; touches nothing
#     --suggest-excepts       print an except list derived from THIS cluster
#     --help, -h              this text
#
#   Environment:
#     PI_CAGE_POLICY_ENGINE      override CNI DaemonSet name detection
#     PI_CAGE_POLICY_ENGINE_NS   namespace of that DaemonSet
#
# PORTABILITY
#
#   Nothing here is tuned to one cluster. The except list in
#   deploy/k8s/networkpolicy.yaml is a TEMPLATE: preflight reads this cluster's
#   own Pod CIDRs and Service ClusterIP and fails if the loaded policy does not
#   cover them. If it does not, `--suggest-excepts` prints a list that will.
#
# WHAT THIS VERIFIES, AND WHAT IT DOES NOT
#
#   It verifies the KUBERNETES boundary: the NetworkPolicies in
#   deploy/k8s/networkpolicy.yaml, as they are actually loaded in the cluster.
#
#   It does NOT verify plain-Docker deployments. Compose has no egress control,
#   so on a single Docker host the network boundary is whatever your firewall
#   says -- pi-cage does not provide one there. Do not read a green run of this
#   script as covering a compose deployment.
#
# THE ONE READING RULE THAT MATTERS
#
#   "Must be refused" is the hard criterion. "Must be reachable" is a smoke test
#   and nothing more.
#
#   Reason: this network's router runs a transparent proxy, so ANY public
#   address:port answers CONNECTED -- including unroutable test ranges like
#   192.0.2.1. Reachability therefore only proves the packet left the container,
#   not that anything answered. A dropped packet, by contrast, never leaves the
#   node, so the proxy cannot fake it. The denial direction is the real evidence.
#
#   Note also that a connection REFUSED (RST) means the packet ARRIVED. It is
#   never scored as blocked -- scoring it blocked would manufacture a pass.

set -Eeuo pipefail

NS="${NS:-pi-cage}"
DEPLOY="${DEPLOY:-pi-cage}"
CONTAINER="${CONTAINER:-pi-cage}"
EXPLAIN=0
SUGGEST=0
OUTSIDER=1
ALSO_BLOCKED=()
ALSO_REACHABLE=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace) NS="$2"; shift 2 ;;
        --deploy)    DEPLOY="$2"; shift 2 ;;
        --container) CONTAINER="$2"; shift 2 ;;
        --also-blocked)   ALSO_BLOCKED+=("$2"); shift 2 ;;
        --also-reachable) ALSO_REACHABLE+=("$2"); shift 2 ;;
        --no-outsider) OUTSIDER=0; shift ;;
        --explain) EXPLAIN=1; shift ;;
        --suggest-excepts) SUGGEST=1; shift ;;
        --help|-h) sed -n '2,48p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- the matrix --
# Targets that must be REFUSED. Names are resolved inside the container; the
# node's own address is appended at runtime because it differs per cluster.
INTERNAL=(
    kubernetes.default.svc:443
)
METADATA="169.254.169.254:80"

# Targets that must be REACHABLE (smoke test only -- see the header).
PUBLIC=(
    github.com:443
    registry.npmjs.org:443
)
PUBLIC+=("${ALSO_REACHABLE[@]+"${ALSO_REACHABLE[@]}"}")
INTERNAL+=("${ALSO_BLOCKED[@]+"${ALSO_BLOCKED[@]}"}")

# Names that must RESOLVE. A name that does not resolve makes the policy
# untestable, which is different from the policy being wrong.
DNS_NAMES=(
    kubernetes.default.svc.cluster.local
    github.com
)

# Ranges that every sane except list carries. These are DEFAULTS, not the
# requirement -- see the cluster-coverage check in preflight, which is the one
# that actually matters.
#
# 198.18.0.0/15 is the single most expensive mistake available here. It looks
# like harmless RFC 2544 benchmark space, but a network running Clash/OpenClash
# fake-ip DNS resolves EVERY external name into it -- one line, and the entire
# public internet is excluded, model API included. Measured the hard way.
REQUIRED_EXCEPTS=(
    10.0.0.0/8
    172.16.0.0/12
    192.168.0.0/16
    127.0.0.0/8
    169.254.0.0/16
    100.64.0.0/10
)
FORBIDDEN_EXCEPT='198\.18\.'

ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  warn  %s\n' "$1"; }
FAIL=0

# ---------------------------------------------------------------------------
# IPv4 containment. The except list is a TEMPLATE that has to cover whatever
# CIDRs THIS cluster puts its Pods and Services in -- which is not knowable in
# advance and differs between kubeadm, k3s, EKS, GKE, and a home lab. Checking
# only that the well-known ranges are present would report a clean boundary on a
# cluster whose 198.19.0.0/16 Pod CIDR is wide open. That is a silent false
# green, which is worse than a false red.
# ---------------------------------------------------------------------------
ip_to_int() { # ip_to_int <a.b.c.d> -> integer, or non-zero exit if malformed
    local a b c d
    IFS=. read -r a b c d <<<"$1" || return 1
    local o
    for o in "$a" "$b" "$c" "$d"; do
        case "$o" in ''|*[!0-9]*) return 1 ;; esac
        [ "$o" -le 255 ] || return 1
    done
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

cidr_contains() { # cidr_contains <cidr> <ip>
    local cidr="$1" ip="$2" net bits
    case "$cidr" in */*) ;; *) return 1 ;; esac
    net="${cidr%%/*}"; bits="${cidr##*/}"
    case "$bits" in ''|*[!0-9]*) return 1 ;; esac
    [ "$bits" -le 32 ] || return 1
    local n i mask
    n="$(ip_to_int "$net")" || return 1
    i="$(ip_to_int "$ip")" || return 1
    if [ "$bits" -eq 0 ]; then mask=0; else mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF )); fi
    [ $(( n & mask )) -eq $(( i & mask )) ]
}

covered_by_excepts() { # covered_by_excepts <ip> -> prints the matching except, or empty
    local ip="$1" c
    while read -r c; do
        [ -n "$c" ] || continue
        if cidr_contains "$c" "$ip"; then printf '%s' "$c"; return 0; fi
    done <<<"$EXCEPTS"
    return 1
}

discover_node() {
    kubectl -n "$NS" get pod -l "app=$DEPLOY" \
        -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true
}

# A dead end is not a useful failure mode. When there is no schedulable Pod, say
# why and what to do about it -- an unschedulable Pod and an unpullable image
# look identical from the outside ("nothing happened"), and the fixes are in
# completely different files.
diagnose_pods() {
    local rows
    rows="$(kubectl -n "$NS" get pods -l "app=$DEPLOY" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{range .status.containerStatuses[*]}{.name}={.state.waiting.reason}{.state.terminated.reason}{" "}{end}{"|"}{.status.conditions[?(@.type=="PodScheduled")].message}{"\n"}{end}' \
        2>/dev/null || true)"

    if [[ -z "$rows" ]]; then
        echo "    No Pod with label app=$DEPLOY exists at all."
        echo "    Nothing is creating one. Check the Deployment:"
        echo "      kubectl -n $NS describe deploy/$DEPLOY"
        echo "      kubectl -n $NS get events --sort-by=.lastTimestamp | tail -20"
        return
    fi

    local name phase states msg
    while IFS='|' read -r name phase states msg; do
        [[ -n "$name" ]] || continue
        echo "    $name  phase=${phase:-?}  ${states:-<no container status>}"
        [[ -n "$msg" ]] && echo "      scheduling: $msg"

        case "$states" in
            *ImagePullBackOff*|*ErrImagePull*|*InvalidImageName*)
                echo "      -> the node cannot pull that image."
                echo "         The manifests ship a reference that is NOT published, so this"
                echo "         is the expected first-run failure. See deploy/k8s/README.md."
                echo "         Current reference:"
                echo "           kubectl -n $NS get deploy/$DEPLOY -o jsonpath='{.spec.template.spec.containers[0].image}'"
                ;;
            *CreateContainerConfigError*)
                echo "      -> usually a missing ConfigMap, Secret or volume."
                ;;
            *CrashLoopBackOff*)
                echo "      -> the container starts and exits. Logs:"
                echo "           kubectl -n $NS logs deploy/$DEPLOY -c $CONTAINER --previous --tail=50"
                ;;
        esac
    done <<< "$rows"

    # Unbound PersistentVolumeClaims block scheduling with an empty nodeName --
    # which is indistinguishable from "the image cannot be pulled" unless you
    # look here. Worth checking explicitly.
    local unbound
    unbound="$(kubectl -n "$NS" get pvc \
        -o jsonpath='{range .items[?(@.status.phase!="Bound")]}{.metadata.name}={.status.phase}:{.spec.storageClassName} {end}' \
        2>/dev/null || true)"
    if [[ -n "$unbound" ]]; then
        echo "    Unbound PVC(s): $unbound"
        echo "      -> set storageClassName in deploy/k8s/core.yaml to a class your"
        echo "         cluster actually has, or omit it to use the cluster default:"
        echo "           kubectl get storageclass"
    fi
}

NODE="$(discover_node)"
NODE_IP=""
NODE_TARGET=""
if [[ -n "$NODE" ]]; then
    NODE_IP="$(kubectl get node "$NODE" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
    # A node can report several InternalIPs; refuse to guess which one to probe.
    if [[ -n "$NODE_IP" && "$NODE_IP" != *' '* ]]; then
        NODE_TARGET="${NODE_IP}:22"
        INTERNAL+=("$NODE_TARGET")
    fi
fi

if [[ "$EXPLAIN" == 1 ]]; then
    echo "=== Expectations (--explain; no cluster was contacted) ==="
    printf '  %-46s %s\n' "target" "expected"
    for t in "${INTERNAL[@]}"; do
        printf '  %-46s %s\n' "$t" "REFUSED (TIMEOUT / ENETUNREACH)"
    done
    printf '  %-46s %s\n' "$METADATA" "REFUSED"
    for t in "${PUBLIC[@]}"; do
        printf '  %-46s %s\n' "$t" "reachable (CONNECTED; RST also counts)"
    done
    for n in "${DNS_NAMES[@]}"; do
        printf '  %-46s %s\n' "dns:$n" "must resolve"
    done
    echo
    echo "  {node} is substituted at runtime with the node the Pod runs on."
    echo "  A connection REFUSED means the packet arrived and is scored reachable,"
    echo "  never blocked."
    echo
    echo "  Cluster-wide expectations checked in preflight:"
    echo "    - policies default-deny / proxy-ingress / public-egress all present"
    echo "    - default-deny covers Ingress AND Egress"
    echo "    - public-egress except list omits 198.18.0.0/15 (fake-ip trap)"
    echo "    - public-egress except list contains: ${REQUIRED_EXCEPTS[*]}"
    echo "    - public-egress grants no cluster-internal destination"
    echo "    - proxy-ingress admits only pods labelled pi-cage-client=true"
    exit 0
fi

command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }

# ---------------------------------------------------------------------------
# --suggest-excepts: print an except list sized for THIS cluster.
#
# The shipped networkpolicy.yaml carries a template. It happens to fit clusters
# whose Pods and Services live in 10/8, 172.16/12 or 192.168/16 -- which is most
# of them, but not all. Rather than making every reader work out their own CIDRs,
# ask the cluster.
# ---------------------------------------------------------------------------
if [[ "$SUGGEST" == 1 ]]; then
    echo "=== except list for THIS cluster ==="
    echo
    echo "# Derived from the cluster on $(date -u +%Y-%m-%d). CIDRs are widened to"
    echo "# /16 where that is safe, matching the shipped template's style."
    echo "            except:"
    for cidr in "${REQUIRED_EXCEPTS[@]}"; do printf '              - %s\n' "$cidr"; done
    echo "              - 0.0.0.0/8"
    echo "              - 224.0.0.0/4"
    echo "              - 240.0.0.0/4"
    echo "              - 192.0.0.0/24"
    echo "              - 192.88.99.0/24"
    echo "              - 255.255.255.255/32"
    echo
    echo "  # From this cluster's own configuration:"
    found=0
    while read -r c; do
        [ -n "$c" ] || continue
        found=1
        printf '              - %s    # node Pod CIDR\n' "$c"
    done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.spec.podCIDR}{"\n"}{end}' 2>/dev/null | sort -u | grep -v '^$' || true)
    svcip="$(kubectl -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
    case "$svcip" in
        ''|None) ;;
        *) found=1
           printf '              - %s    # covers the kubernetes Service; widen if your Service CIDR is larger\n' \
               "$(printf '%s' "$svcip" | awk -F. '{print $1"."$2".0.0/16"}')" ;;
    esac
    if [[ "$found" == 0 ]]; then
        echo "              # (could not read podCIDR or the Service ClusterIP)"
        echo "              # Look at your kube-controller-manager flags instead:"
        echo "              #   --cluster-cidr and --service-cluster-ip-range"
        echo "              # On kubeadm: kubectl -n kube-system get pod kube-controller-manager-<node> -o yaml | grep -- --cluster"
    fi
    echo
    echo "  # NEVER add 198.18.0.0/15. On a Clash/OpenClash fake-ip network every"
    echo "  # external name resolves into it, so excluding it excludes the public"
    echo "  # internet -- model API included."
    exit 0
fi

# ------------------------------------------------------------------ preflight --
echo "=== 0. preflight ==="

if ! kubectl -n "$NS" get "deploy/$DEPLOY" >/dev/null 2>&1; then
    echo "  No deployment/$DEPLOY in namespace $NS." >&2
    echo "  Deploy first:  kubectl apply -k deploy/k8s" >&2
    exit 1
fi
ok "deployment/$DEPLOY exists (ns $NS, container $CONTAINER)"

if [[ -z "$NODE" ]]; then
    echo "  No Pod is scheduled for deployment/$DEPLOY, so there is nothing to" >&2
    echo "  probe. Refusing to report a verdict -- a green run that probed nothing" >&2
    echo "  is worse than no run." >&2
    echo >&2
    diagnose_pods >&2
    exit 1
fi
ok "scheduled on $NODE"

# The policy engine must cover THAT node. A policy is enforced by the node's
# kubelet/CNI agent; probing on an uncovered node reports everything reachable
# and looks like a boundary failure when it is really a coverage problem.
#
# Detection covers the engines that actually implement NetworkPolicy. Override
# with PI_CAGE_POLICY_ENGINE / PI_CAGE_POLICY_ENGINE_NS if yours is not listed --
# a hard-coded list would otherwise turn "unknown CNI" into "no boundary", which
# is the wrong conclusion.
ENGINE="${PI_CAGE_POLICY_ENGINE:-}"
NS_ENG="${PI_CAGE_POLICY_ENGINE_NS:-}"
if [[ -z "$ENGINE" ]]; then
    for candidate in \
        "kube-system:calico-node" \
        "kube-system:cilium" \
        "kube-system:antrea-agent" \
        "kube-system:aws-node" \
        "kube-system:azure-cni-networkmonitor" \
        "kube-router:kube-router" \
        "kube-system:kube-router"
    do
        ns_c="${candidate%%:*}"; ds_c="${candidate##*:}"
        if kubectl -n "$ns_c" get ds "$ds_c" >/dev/null 2>&1; then
            ENGINE="$ds_c"; NS_ENG="$ns_c"; break
        fi
    done
fi
if [[ -z "$ENGINE" ]]; then
    echo "  No known NetworkPolicy engine found on this cluster." >&2
    echo "  Looked for: calico-node, cilium, antrea-agent, aws-node," >&2
    echo "              azure-cni-networkmonitor, kube-router." >&2
    echo >&2
    echo "  NOTE: this is not necessarily a failure. Some CNIs implement" >&2
    echo "  NetworkPolicy under a different name, and flannel does not implement" >&2
    echo "  it at all. Find yours and name it:" >&2
    echo "    kubectl get ds -A | grep -iE 'calico|cilium|antrea|weave|kube-router|ovn'" >&2
    echo "    PI_CAGE_POLICY_ENGINE=<ds-name> PI_CAGE_POLICY_ENGINE_NS=<ns> $0" >&2
    echo >&2
    echo "  If your CNI genuinely does not implement NetworkPolicy, every policy" >&2
    echo "  in deploy/k8s is inert and this script cannot tell you anything." >&2
    exit 1
fi
if [[ "$(kubectl -n "$NS_ENG" get pods -l "k8s-app=$ENGINE" \
        -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null)" != *"$NODE"* ]]; then
    echo "  $ENGINE does not cover $NODE; policy is not enforced there." >&2
    exit 1
fi
ok "policy engine $ENGINE covers $NODE"

# Read the CLUSTER's policy, never the repository's copy. "Committed" is not
# "loaded" -- a sibling cluster spent a day on exactly that distinction.
for p in default-deny proxy-ingress public-egress; do
    if kubectl -n "$NS" get networkpolicy "$p" >/dev/null 2>&1; then
        ok "networkpolicy/$p is loaded"
    else
        echo "  networkpolicy/$p is missing from the cluster." >&2
        echo "  Apply it:  kubectl apply -k deploy/k8s" >&2
        exit 1
    fi
done

TYPES="$(kubectl -n "$NS" get networkpolicy default-deny \
         -o jsonpath='{.spec.policyTypes[*]}' 2>/dev/null || true)"
if [[ "$TYPES" == *Ingress* && "$TYPES" == *Egress* ]]; then
    ok "default-deny covers both directions"
else
    bad "default-deny policyTypes is '$TYPES' -- both Ingress and Egress are required"
fi

# jsonpath returns the except entries SPACE-separated on one line. Normalise to
# one CIDR per line first -- with `grep -x` against the raw line, every check
# below would silently fail to match and report a clean boundary that was never
# inspected.
EXCEPTS="$(kubectl -n "$NS" get networkpolicy public-egress \
           -o jsonpath='{.spec.egress[*].to[*].ipBlock.except[*]}' 2>/dev/null \
           | tr ' ' '\n' | grep -v '^$' || true)"

if grep -q "$FORBIDDEN_EXCEPT" <<<"$EXCEPTS"; then
    echo "  public-egress lists 198.18.0.0/15 in its except list." >&2
    echo "  This network's fake-ip DNS resolves EVERY external name into that" >&2
    echo "  range, so this one line excludes the entire public internet --" >&2
    echo "  including the model API. Remove it and re-apply:" >&2
    echo "    kubectl apply -k deploy/k8s" >&2
    exit 1
fi
ok "public-egress omits 198.18.0.0/15 (the fake-ip trap)"

MISSING=()
for cidr in "${REQUIRED_EXCEPTS[@]}"; do
    grep -qxF "$cidr" <<<"$EXCEPTS" || MISSING+=("$cidr")
done
if [[ ${#MISSING[@]} -eq 0 ]]; then
    ok "public-egress excludes the customary internal ranges"
else
    # Not fatal on its own: what matters is whether THIS cluster's addresses are
    # covered, which is checked immediately below.
    warn "public-egress does not list: ${MISSING[*]} (fine only if your cluster has no addresses there)"
fi

# ---------------------------------------------------------------------------
# THE CHECK THAT ACTUALLY MATTERS, and the one a hard-coded template misses.
#
# The except list has to cover whatever CIDRs this cluster puts its Pods and
# Services in. Those differ between kubeadm, k3s, kind, EKS, GKE, and a home
# lab, so a list tuned to one cluster can leave another wide open -- while every
# check above still passes. Ask the cluster what it actually uses.
# ---------------------------------------------------------------------------
CLUSTER_ADDRS=()
while read -r c; do
    [ -n "$c" ] || continue
    # podCIDR is "10.244.0.0/24"; test its network address.
    CLUSTER_ADDRS+=("${c%%/*}|Pod CIDR on a node")
done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.spec.podCIDR}{"\n"}{end}' 2>/dev/null | grep -v '^$' || true)

KUBE_SVC_IP="$(kubectl -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
case "$KUBE_SVC_IP" in ''|None) ;; *) CLUSTER_ADDRS+=("${KUBE_SVC_IP}|the kubernetes Service (Service CIDR)") ;; esac

if [[ ${#CLUSTER_ADDRS[@]} -eq 0 ]]; then
    warn "could not determine this cluster's Pod/Service addresses; cannot prove the except list covers them"
else
    UNCOVERED=()
    for entry in "${CLUSTER_ADDRS[@]}"; do
        addr="${entry%%|*}"; what="${entry##*|}"
        if covered_by_excepts "$addr" >/dev/null; then
            ok "except covers ${what}: ${addr}"
        else
            bad "${what} ${addr} is NOT covered by any except entry -- the container can reach your cluster"
            UNCOVERED+=("$addr")
        fi
    done
    if [[ ${#UNCOVERED[@]} -gt 0 ]]; then
        echo "      Add these to the except list in deploy/k8s/networkpolicy.yaml:" >&2
        for u in "${UNCOVERED[@]}"; do
            # Widen the address to a /16 so one entry covers the neighbourhood,
            # which is what the shipped template does for 10/8 and friends.
            echo "        - $(printf '%s' "$u" | awk -F. '{print $1"."$2".0.0/16"}')" >&2
        done
        echo "      Then:  kubectl apply -k deploy/k8s" >&2
    fi
fi

# If anything grants a cluster-internal destination besides DNS, the expectation
# table above is stale and a green run would be meaningless.
#
# The allowance is 2, not 1, because the shipped policy lists two DNS label
# variants (k8s-app=kube-dns and k8s-app=coredns) so that a cluster using either
# still resolves. This check broke the first time that second entry was added --
# a hard-coded count in a verifier is the same trap as a hard-coded CIDR list.
# If you add a third cluster-internal grant, raise this deliberately and say why.
DNS_ENTRIES_EXPECTED=2
CLUSTER_GRANTS="$(kubectl -n "$NS" get networkpolicy public-egress \
    -o jsonpath='{range .spec.egress[*].to[*]}{.namespaceSelector}{.podSelector}{"\n"}{end}' \
    2>/dev/null | grep -c . || true)"
if [[ "${CLUSTER_GRANTS:-0}" -le "$DNS_ENTRIES_EXPECTED" ]]; then
    ok "public-egress grants no cluster-internal destination beyond DNS (${CLUSTER_GRANTS} of ${DNS_ENTRIES_EXPECTED} allowed)"
else
    bad "public-egress grants ${CLUSTER_GRANTS} cluster-internal destinations but this script only expects ${DNS_ENTRIES_EXPECTED}; the expectation table is stale -- update it before trusting a green run"
fi

# Do not address the hyphenated label as a jsonpath field (`{.matchLabels.pi-cage-client}`
# is not portable); read the whole map and match its rendering instead.
#
# kubectl renders that map as JSON ({"pi-cage-client":"true"}) at least as often
# as the Go form (map[pi-cage-client:true]). The first version of this check
# matched only the latter, so it reported a correctly labelled policy as a
# failure. Match key and value separately and tolerate both renderings.
INGRESS_LABELS="$(kubectl -n "$NS" get networkpolicy proxy-ingress \
    -o jsonpath='{.spec.ingress[0].from[0].podSelector.matchLabels}' 2>/dev/null || true)"
case "$INGRESS_LABELS" in
    *pi-cage-client*true*)
        ok "proxy-ingress admits only pods labelled pi-cage-client=true" ;;
    *)
        bad "proxy-ingress does not require pi-cage-client=true (got '${INGRESS_LABELS:-<none>}') -- anything in the cluster could reach the web terminal" ;;
esac

echo
echo "  Probing from the real container, not a throwaway probe Pod."

# ----------------------------------------------------------------- the probe --
# Runs inside the pi-cage container. Node is guaranteed present (the image is
# node-based) and the root filesystem is read-only, so `node -e` writes nothing.
read -r -d '' PROBE_JS <<'JS' || true
const net = require('net');
const dns = require('dns');

const targets = process.argv.slice(1);
// Per-address connect timeout, and the whole run's wall clock since targets are
// probed in parallel. Long enough that a slow public host is not misread as
// dropped -- a false "blocked" would hide a real boundary failure.
const TIMEOUT_MS = 5000;

// Only a timeout or an unreachable-network error means the packet was dropped.
// An RST (ECONNREFUSED / ECONNRESET) means it ARRIVED: that is what a reachable
// host with no listener looks like. Scoring it blocked manufactures a pass.
function classify(err) {
  if (!err) return { rank: 3, label: 'REACHABLE(CONNECTED)' };
  const c = err.code;
  if (c === 'ECONNREFUSED') return { rank: 2, label: 'REACHABLE(ECONNREFUSED)' };
  if (c === 'ECONNRESET')   return { rank: 2, label: 'REACHABLE(ECONNRESET)' };
  if (c === 'ETIMEDOUT')    return { rank: 1, label: 'DROPPED(timeout)' };
  if (c === 'ENETUNREACH' || c === 'EHOSTUNREACH' || c === 'EACCES' || c === 'EPERM')
    return { rank: 1, label: 'BLOCKED(' + c + ')' };
  return { rank: 0, label: 'ERROR(' + c + ')' };
}

function connect(addr, port, cb) {
  const s = net.connect(port, addr);
  let settled = false;
  const finish = v => { if (!settled) { settled = true; s.destroy(); cb(v); } };
  s.on('connect', () => finish(classify(null)));
  s.on('error', e => finish(classify(e)));
  s.setTimeout(TIMEOUT_MS, () => finish(classify({ code: 'ETIMEDOUT' })));
}

const results = [];
let pending = targets.length;
function emit(line) {
  results.push(line);
  if (--pending === 0) {
    results.sort();
    for (const l of results) console.log('RESULT ' + l);
    process.exit(0);
  }
}

for (const t of targets) {
  const i = t.lastIndexOf(':');
  const host = t.slice(0, i), port = Number(t.slice(i + 1));
  const literal = net.isIP(host) !== 0;
  const look = cb => literal ? cb(null, [host])
    : dns.lookup(host, { all: true }, (e, a) => cb(e, (a || []).map(x => x.address)));

  look((err, addrs) => {
    // A target that never emits would hang the whole run waiting for it.
    if (err) return emit(t + ' NORESOLVE(' + err.code + ') addrs=-');
    if (!addrs.length) return emit(t + ' NORESOLVE(EMPTY) addrs=-');
    // Probe every resolved address and keep the most reachable outcome: the
    // boundary is about what the container CAN reach, so a single reachable
    // address makes the target reachable.
    let left = addrs.length, best = null;
    for (const a of addrs) {
      connect(a, port, v => {
        if (!best || v.rank > best.rank) best = v;
        if (--left === 0) emit(t + ' ' + best.label + ' addrs=' + addrs.join(','));
      });
    }
  });
}
JS

DNS_JS='require("dns").lookup(process.argv[1],{all:true},(e,a)=>{console.log(e?("RESOLVE "+process.argv[1]+" FAIL("+e.code+")"):("RESOLVE "+process.argv[1]+" ok addrs="+a.map(x=>x.address).join(",")));});'

probe() {
    kubectl -n "$NS" exec "deploy/$DEPLOY" -c "$CONTAINER" \
        -- node -e "$PROBE_JS" "$@" 2>/dev/null | sed -n 's/^RESULT //p'
}
probe_dns() {
    kubectl -n "$NS" exec "deploy/$DEPLOY" -c "$CONTAINER" \
        -- node -e "$DNS_JS" "$1" 2>/dev/null | sed -n 's/^RESOLVE //p'
}

# A target with no RESULT line must be reported as missing, not abort the run;
# without `|| true` the failing grep inside $( ) trips `set -e`.
verdict_of() { grep -F "$1 " <<<"$RAW" | head -1 | awk '{print $2}' || true; }
addrs_of()   { grep -F "$1 " <<<"$RAW" | head -1 | awk -F'addrs=' 'NF>1{print $2}' || true; }

echo
echo "=== 1. probe (inside the container) ==="
RAW="$(probe "${INTERNAL[@]}" "$METADATA" "${PUBLIC[@]}")"
if [[ -z "$RAW" ]]; then
    echo "  The probe returned nothing: kubectl exec failed, or node is absent." >&2
    exit 1
fi
ok "received $(wc -l <<<"$RAW") probe result(s)"

echo
echo "=== 2. internal + metadata: MUST be refused (this is the hard criterion) ==="
for t in "${INTERNAL[@]}" "$METADATA"; do
    v="$(verdict_of "$t")"
    case "$v" in
        DROPPED*|BLOCKED*) ok "$(printf '%-42s %s' "$t" "$v")" ;;
        REACHABLE*)        bad "$(printf '%-42s %s  <- reachable; the boundary does not hold' "$t" "$v")" ;;
        NORESOLVE*)        bad "$(printf '%-42s %s  <- did not resolve; cannot judge the policy' "$t" "$v")" ;;
        *)                 bad "$(printf '%-42s %s' "$t" "${v:-<no result>}")" ;;
    esac
done

echo
echo "=== 3. public: should be reachable (smoke test only) ==="
echo "  Note: this network answers CONNECTED for ANY public address:port, so a"
echo "  pass here proves only that the packet left the container."
for t in "${PUBLIC[@]}"; do
    v="$(verdict_of "$t")"
    a="$(addrs_of "$t")"
    case "$v" in
        REACHABLE*)
            if [[ "$a" == 198.18.* ]]; then
                # Informational, not a defect. On a Clash/OpenClash fake-ip
                # network every public name resolves into 198.18.0.0/15 and the
                # router's transparent proxy answers -- which is exactly why the
                # except list must OMIT that range. Preflight already proved it
                # does; this line only tells you the fake-ip is in play.
                warn "$(printf '%-42s %s  <- fake-ip resolution (198.18.0.0/15); expected on this network, harmless while except omits it' "$t" "$v")"
            else
                ok "$(printf '%-42s %s  addrs=%s' "$t" "$v" "$a")"
            fi
            ;;
        NORESOLVE*) bad "$(printf '%-42s %s  <- public DNS is not working; egress is broken' "$t" "$v")" ;;
        *)          bad "$(printf '%-42s %s  <- not reachable' "$t" "${v:-<no result>}")" ;;
    esac
done

echo
echo "=== 4. DNS resolution ==="
for n in "${DNS_NAMES[@]}"; do
    r="$(probe_dns "$n")"
    case "$r" in
        *" ok "*) ok "$(printf '%-42s %s' "$n" "$r")" ;;
        "")       bad "$(printf '%-42s no result' "$n")" ;;
        *)        bad "$(printf '%-42s %s' "$n" "$r")" ;;
    esac
done

if [[ "$OUTSIDER" == 1 ]]; then
    echo
    echo "=== 5. ingress: an unlabelled pod must NOT reach the web terminal ==="
    IMAGE="$(kubectl -n "$NS" get "deploy/$DEPLOY" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    if [[ -z "$IMAGE" ]]; then
        bad "could not determine the deployment image; skipping the outsider probe"
    else
        # Reuse pi-cage's own image: it is already on the node (no pull) and has
        # node, so it can run the same connect logic.
        OUT_NAME="pi-cage-outsider-$$"
        OUT_NS="${OUTSIDER_NS:-default}"
        OUT_HOST="pi-cage.${NS}.svc.cluster.local"
        # Built with double quotes so ${OUT_HOST} expands; the JS itself uses
        # single quotes internally. Splitting the quoting across two languages
        # inline is how this kind of probe usually ends up silently broken.
        OUT_JS="const net=require('net');
const s=net.connect(7681,'${OUT_HOST}');
let done=false;
const fin=v=>{if(!done){done=true;s.destroy();console.log('OUTSIDER '+v);process.exit(0);}};
s.on('connect',()=>fin('REACHABLE'));
s.on('error',e=>fin((e.code==='ECONNREFUSED'||e.code==='ECONNRESET')?'REACHABLE('+e.code+')':'BLOCKED('+e.code+')'));
s.setTimeout(5000,()=>fin('BLOCKED(timeout)'));"
        kubectl -n "$OUT_NS" delete pod "$OUT_NAME" --ignore-not-found >/dev/null 2>&1 || true
        if kubectl -n "$OUT_NS" run "$OUT_NAME" --restart=Never --image="$IMAGE" \
             --command -- node -e "$OUT_JS" >/dev/null 2>&1; then
            OUT_LINE=""
            for _ in $(seq 1 20); do
                OUT_LINE="$(kubectl -n "$OUT_NS" logs "$OUT_NAME" 2>/dev/null | sed -n 's/^OUTSIDER //p' | head -1 || true)"
                [[ -n "$OUT_LINE" ]] && break
                sleep 1
            done
            kubectl -n "$OUT_NS" delete pod "$OUT_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
            case "$OUT_LINE" in
                BLOCKED*)   ok "an unlabelled pod in ns $OUT_NS cannot reach ${OUT_HOST}:7681 ($OUT_LINE)" ;;
                REACHABLE*) bad "an unlabelled pod reached the web terminal ($OUT_LINE) -- proxy-ingress is not admitting only labelled sources" ;;
                *)          warn "outsider probe produced no verdict (${OUT_LINE:-no output}); inspect ns $OUT_NS" ;;
            esac
        else
            warn "could not start the outsider Pod in ns $OUT_NS; section skipped"
        fi
    fi
else
    echo
    echo "=== 5. ingress check skipped (--no-outsider) ==="
fi

echo
echo "=== 6. not covered ==="
echo "  - IPv6: the NetworkPolicy ipBlock rules are IPv4 only. Confirm your nodes"
echo "    have no IPv6 egress, or add equivalent rules."
echo "  - Plain Docker / compose: no egress control is provided there. A green run"
echo "    of this script says nothing about a compose deployment."

echo
if [[ "$FAIL" == 0 ]]; then
    echo "All checks passed."
else
    echo "$FAIL check(s) FAILED." >&2
fi
exit $(( FAIL > 0 ? 1 : 0 ))
