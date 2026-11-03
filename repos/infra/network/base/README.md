# `repos/infra/network/base` — the platform network baseline

## Two layers, on purpose

| Layer | Object | Where it comes from | Who can change it | What it is for |
| --- | --- | --- | --- | --- |
| 1. team-visible | `NetworkPolicy team-baseline-default-deny`, one per workload namespace | `ResourceSet teams` (`repos/fleet/base/teams.yaml`) | the **team** holds `admin` in its workload namespaces, so it can edit or replace it — but not delete it, because `team-baseline-lock` (VAP) denies writes to `team-baseline-*` | the default-deny, and the documentation of it. `kubectl -n team-a-apps get netpol` shows a team exactly what it is allowed to reach: its own namespaces, kube-dns, and the public internet. A call to another team that no rule declares does not land |
| 2. cluster-wide baseline | `platform-dns-allow`, `teams-deny-platform` (this directory); `platform-host-probes`, `allow-ambient-hostprobes` (`repos/infra/network/envs/local/host-probes.yaml`) | `infra` artifact → `infra-ks` | devops only — a CCNP is cluster-scoped and no team RBAC reaches it | DNS reachable everywhere, node-local health probes allowed everywhere, and every team kept out of the platform namespaces |

### The layer that was removed

Round one had a third layer: `CiliumClusterwideNetworkPolicy
team-<team>-isolation`, one per team, with `ingressDeny`/`egressDeny`. It is
gone.

In Cilium **deny beats allow**, with no ordering and no exception. A per-team
deny is therefore a wall that no later allow can open a door in — not by the
owning team, not by devops, not by a reviewed declaration in git. That was the
right shape for the round-one story ("teams are adversaries") and the wrong
shape for a company platform, where one team calling another's service is a
first-class, reviewed dependency rather than an attack.

What replaces it is layer 1 doing its job: the baseline is default-deny in both
directions, and the only way in is an explicit `ingress.from` the owning team
ships in its own repo. The deny is still enforced, just not by an object nobody
can argue with — and the verdict moves from `Policy denied by denylist` to
`EGRESS DENIED` on the sending side, where the caller's own baseline has no
matching rule.

## What is in this directory

`platform-dns-allow` and `teams-deny-platform` are in
`platform-baseline.yaml`. The two probe policies below are **not**: both exist
only because this runtime is k3d on Docker Desktop, so they live in
`repos/infra/network/envs/local/host-probes.yaml` and a second environment starts
without them. They are still part of the same
`infra-ks` revision, applied in the same order as before — `envs/local` only
changes which file declares them.

### `platform-host-probes`

Allows ingress from `host`, `remote-node` and `world` to every endpoint, with
`enableDefaultDeny` off so it is purely additive.

It exists because of a measured Cilium behaviour on this stack, not because the
team policies are wrong: a kubelet health probe leaves the node through
`cilium_host` and reaches the pod's policy program carrying `reserved:world`
(identity 2) rather than `reserved:host` (identity 1), even though
`cilium-dbg ip list` resolves that address to `reserved:host` and the endpoint's
BPF policy map already holds `Allow Ingress reserved:host`. The auto
`allow-localhost` exemption therefore never matches and every probe is dropped
the moment a namespace has a default-deny policy:

```
policy-verdict:none INGRESS DENIED  10.42.1.4:60664 (world) <>
  flux-system/source-controller:9440 (ID:2071)   Policy denied DROPPED
```

Without this rule no team pod can ever pass its own liveness probe. Four
candidate fixes were measured node by node and none changed the verdict:
`allow-localhost: always`, `hostFirewall.enabled: true`,
`bpf.hostLegacyRouting: false`, and full `kubeProxyReplacement: true`.

The `world` entry is the part worth stating plainly, and its blast radius is
small: on this single-laptop cluster the only addresses Cilium calls `world` are
the node stacks, the k3d load balancer and the local registry container, and
neither of the latter two has a route into the pod CIDR. **Cross-team traffic is
unaffected** - it carries real per-namespace Cilium identities, so the team's
baseline `NetworkPolicy` still denies it, which the `demo-netpol` output below
demonstrates.

### `platform-dns-allow`

Selects every pod except `kube-system` and `k8s-app: kube-dns`, and allows
egress to kube-dns on port 53.

`enableDefaultDeny: {egress: false, ingress: false}` is load-bearing. A
cluster-wide rule that carries an `egress:` section would otherwise flip **every
pod in the cluster** into egress default-deny with DNS as the only allowed
destination — Flux could no longer reach the registry. With `enableDefaultDeny`
off, Cilium ignores this rule when deciding a pod's enforcement mode, so it is
purely additive.

**There is deliberately no `rules.dns` L7 block, and that is an integration
finding.** The design called for `matchPattern: "*"` so DNS would flow through
Cilium's DNS proxy and `hubble observe` would report FQDNs. On Docker Desktop's
kernel the proxy cannot deliver the answer back to the client:

```
level=error msg="Cannot forward proxied DNS response"
  error="write ip 127.0.0.1->10.42.2.238: sendmsg: operation not permitted"
```

It writes the reply from a transparent socket with a spoofed source address,
which that kernel refuses. The query reaches CoreDNS and the answer reaches the
proxy; only the last hop fails. The symptom is that DNS times out in **every**
team namespace while pod-to-pod by IP still works, so podinfo is Running and
healthy but `curl podinfo.team-b-apps:9898` hangs — which reads like a
NetworkPolicy bug and is not one. `dnsProxy.enableTransparentMode: false` was
tried and changed nothing (the flag no longer switches that path in 1.20.4).

What is lost: `hubble observe --protocol dns` shows flows to kube-dns at L3/L4
but no `DNS Query` / `DNS Answer` lines, and a future `toFQDNs` rule would not
resolve. What is kept: the rule still states, cluster-wide, that DNS is always
reachable, which is the half a cross-team allow depends on. The *allow* itself
is redundant with layer 1.

### `allow-ambient-hostprobes`

Allows ingress `fromCIDR: [169.254.7.127/32]` to every endpoint, with
`enableDefaultDeny` off on both directions — the same shape as
`platform-host-probes`, for a second probe path that only exists once a
namespace is enrolled in Istio ambient.

istio-cni SNATs a kubelet probe to that link-local address before handing it to
the pod, so the probe arrives carrying neither the node's identity nor
`reserved:world`, and `platform-host-probes` does not match it. Without this
rule the first ambient + default-deny namespace crash-loops every pod on its
own readiness probe — the identical failure mode to the round-one finding, from
a different direction.

Kept as a separate object rather than merged into `platform-host-probes`
(which the first design suggested) because the two answer different questions, and
because declaring the CIDR explicitly also pins a Cilium **CIDR identity** for
it. That identity is what makes the probe legible in Hubble:

```
169.254.7.127:33630 (ID:16777220) -> team-d-analytics/chi-analytics-main-0-0-0:8123 (ID:12089) policy-verdict:all INGRESS ALLOWED
```

Note the port: probes reach the **application** port in plaintext, on purpose.
Health probes are outside the mesh and must stay there; everything else between
pods is HBONE on 15008.

### `teams-deny-platform`

Selects every pod in a namespace labelled `platform.k8s-base/team` and denies
egress to `flux-system` and `istio-system` — except a namespace's own
waypoint pods, which are exempted in the selector because they have to reach
istiod on 15012.

`istio-system` was added with the mesh (H1) and costs nothing: a team pod never
talks to istiod, and ztunnel's HBONE connection is opened inside the *caller's*
network namespace to the *destination pod's* IP, so Cilium attributes it to the
two team identities and never to `istio-system`. ztunnel's own xDS stream to
istiod runs from `istio-system` itself and is not selected by a policy that
matches team-labelled namespaces.

The selector key is `io.cilium.k8s.namespace.labels.platform.k8s-base/team`.
Cilium copies namespace labels onto the endpoint under the
`io.cilium.k8s.namespace.labels.` prefix and they are identity-relevant by
default. (`io.kubernetes.pod.namespace.labels.<key>` is not a label Cilium produces.)

Confirmed on the live cluster: the slash inside the label key is not a problem.
`cilium-dbg endpoint list` on a team pod shows

```
k8s:io.cilium.k8s.namespace.labels.platform.k8s-base/team=team-a
```

and `cilium-dbg policy get` shows the CCNP's `Subject` as
`any:io.cilium.k8s.namespace.labels.platform.k8s-base/team: team-a`, so no
slash-free `team: <name>` fallback label was needed.

No `enableDefaultDeny` override here: team pods are already egress-enforced by
their layer-1 NetworkPolicy, and a deny rule must be unconditionally live.

This is the one deny the hardening round keeps. Unlike the per-team isolation
policy that was removed, nothing a team could legitimately want is on the other
side of it: `flux-system` and `istio-system` are the control plane that
reconciles the team, not a service it consumes.

**Egress to the Kubernetes API is not explicitly denied.** Team *pods* have no
reason to talk to the API server: podinfo and the team-b CronJob never do, and
the Flux reconcilers that do run in `flux-system` under their own identity, not
in team pods. Layer 1 already closes it, because its internet rule excludes
`10.0.0.0/8`, `172.16.0.0/12` and `192.168.0.0/16`, which is where the k3d API
server lives — and since H1 layer 1 has no internet rule at all, which closes
it harder still. Adding `- toEntities: [kube-apiserver]` to the `egressDeny` would
be the stricter form; it is left out deliberately, because an operator sidecar
landing in a team namespace later would then fail silently with a timeout
instead of a clear RBAC error.

## Expected `hubble observe` output (`demo-netpol`)

```sh
# undeclared cross-team: must be reset, then show up as a policy drop.
# Give curl more than ztunnel's 10s HBONE deadline or you see a timeout (28)
# instead of ztunnel's reset (56).
kubectl -n team-b-apps exec deploy/podinfo -- curl -m12 -s podinfo.team-a-apps:9898 ; echo "exit=$?"
# exit=56 (connection reset by the caller's own ztunnel)

hubble observe --verdict DROPPED --to-namespace team-a-apps --last 20
# team-b-apps/podinfo-... -> team-a-apps/podinfo-...:15008 TCP Flags: SYN  DROPPED (Policy denied)

# same team, across namespaces: must succeed. team-b-batch runs no server, so
# the direction that can be tested is batch -> apps, from a temporary
# restricted-compliant busybox pod (or the CronJob's own pod).
kubectl -n team-b-batch exec probe -- wget -T5 -q -O- http://podinfo.team-b-apps:9898/healthz
# {"status": "OK"}  (exit 0)

# same team, same namespace
kubectl -n team-b-apps exec deploy/podinfo -- curl -m5 -s -o /dev/null -w '%{http_code}\n' \
  http://podinfo.team-b-apps:9898/
# 200

# team -> platform namespace: denied by teams-deny-platform (this directory)
kubectl -n team-a-apps exec deploy/podinfo -- \
  curl -m3 -s http://source-controller.flux-system/ ; echo "exit=$?"
hubble observe --verdict DROPPED --to-namespace flux-system --last 20
# team-a-apps/podinfo-... -> flux-system/source-controller-... TCP Flags: SYN  DROPPED (Policy denied)

# DNS: flows to kube-dns are visible at L3/L4. There are no `DNS Query` /
# `DNS Answer` lines, because the L7 DNS rule is intentionally absent (above).
hubble observe --protocol dns --from-namespace team-a-apps --last 20
# team-a-apps/podinfo-... -> kube-system/coredns-... to-overlay FORWARDED (UDP)
```

Measured output of the first two commands on the integrated cluster:

```
# undeclared cross-team (layer 1 only, since round two; port 15008 since H1)
policy-verdict:none EGRESS DENIED (TCP Flags: SYN)
  team-b-apps/podinfo-...:41186 (ID:14418) <> team-a-apps/podinfo-...:15008 (ID:28796)
Policy denied DROPPED (TCP Flags: SYN)

# and ztunnel, from the mesh side, on the same connection
error access connection complete
  src.identity="spiffe://cluster.local/ns/team-b-apps/sa/default"
  dst.addr=10.42.1.213:15008 dst.hbone_addr=10.42.1.213:9898
  dst.identity="spiffe://cluster.local/ns/team-a-apps/sa/default"
  error="connection timed out, maybe a NetworkPolicy is blocking HBONE port 15008"

# team -> flux-system (layer 2, teams-deny-platform)
Policy denied by denylist DROPPED (TCP Flags: SYN)
  team-a-apps/podinfo-...:40272 <> flux-system/source-controller-...:9090 (ID:2071)
```

Read the two verdicts as the two layers. `policy-verdict:none EGRESS DENIED` is
layer 1: the caller's own baseline has no rule that matches the destination at
all, so the drop is on the sending side and an owning team can lift it with a
reviewed `ingress.from`. `Policy denied by denylist` is layer 2, and no team can
argue with it. Round one produced the denylist line for a cross-team call too,
because the removed `team-<t>-isolation` CCNP denied it as well; measured
after its removal, a cross-team call reports only the layer-1 wording.

## Validation without a cluster

```sh
kustomize build repos/infra/network/base
# CCNP has no public JSON schema in the kubeconform default bundle:
kubeconform -strict -ignore-missing-schemas repos/infra/network/base/platform-baseline.yaml
# the two k3d-only probe policies are built with envs/local, not with base:
kustomize build repos/infra/network/envs/local
kubeconform -strict -ignore-missing-schemas repos/infra/network/envs/local/host-probes.yaml
```
