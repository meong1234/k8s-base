# `repos/platform/egress/base` — the one way out

Four objects, two owners. The platform owns the exit; `team-sec-ops` owns the
list of what may leave through it (`repos/team-sec-ops/edges/egress-allowlist/base/`, plus the per-environment entries in `repos/team-sec-ops/edges/egress-allowlist/envs/<env>/`).

| Object | What it is for |
| --- | --- |
| `Namespace platform-egress` | ambient-enrolled home of the waypoint pod, PSA `restricted`, prune disabled |
| `Gateway egress-waypoint` | the waypoint, class `istio-waypoint`, `istio.io/waypoint-for: service` |
| `Role` + `RoleBinding egress-waypoint-credentials` | lets the waypoint's own ServiceAccount `get`/`list`/`watch` Secrets in `platform-egress`, which is what a `credentialName` needs |
| `CiliumClusterwideNetworkPolicy platform-egress-to-world` | the only pods in the cluster allowed to reach `world` |

## `egress-waypoint-credentials`: without it, mutual TLS fails silently

When an allow-list entry originates TLS (below), its `DestinationRule` names a
Secret with `trafficPolicy.tls.credentialName`. istiod resolves that credential
**on the proxy's behalf** and gates it with a `SubjectAccessReview` against the
proxy's ServiceAccount — and an auto-deployed waypoint's ServiceAccount
(`egress-waypoint`, named after the Gateway) holds no permission on Secrets. When
the review fails, nothing in the API reports it:

```
$ istioctl proxy-config secret deploy/egress-waypoint -n platform-egress
kubernetes://partner-bank-client                  WARMING   false
kubernetes://partner-bank-client-cacert    CA     ACTIVE    true
```

The `ServiceEntry` still says `WaypointAccepted`, the `DestinationRule` carries
no complaint, and `istioctl proxy-config cluster` shows a complete
`UpstreamTlsContext`. The only trace is a `warn` line in istiod
(`... is not authorized to read secrets`), and the handshake simply never
happens. `WARMING` on the certificate with the `-cacert` half `ACTIVE` is the
tell; `demo-partner-egress` asserts the `ACTIVE` row for exactly this reason.

Three properties of the grant are deliberate:

- **It is the platform's file, not sec-ops'.** The grant says "this waypoint may
  read its own namespace's credentials", which is a property of the waypoint;
  `egress-allowlist` must not be able to widen it.
- **`list` cannot be narrowed to one Secret name.** `resourceNames` does not
  apply to `list`/`watch`, and istiod's review is namespace-scoped rather than
  object-scoped. The blast radius is therefore every Secret in `platform-egress`
  — which is why this namespace holds the waypoint and credentials and nothing
  else, and should stay that way.
- **A denial is cached.** Adding the `RoleBinding` to a running cluster is not
  enough: istiod keeps the refused decision, so the credential stays `WARMING`
  until `kubectl -n platform-egress rollout restart deploy/egress-waypoint`. On a
  clean `make up` it never arises — `platform-ks` applies the `Role` long before
  any `DestinationRule` names a credential.

## Waypoint-originated mutual TLS

Two shapes of allow-list entry reach the world through this waypoint, and they
differ in what can be audited:

| Entry | Port | At the waypoint | What the access log carries |
| --- | --- | --- | --- |
| `api.github.com`, `httpbin.org` | 443 `protocol: TLS` | passthrough, routed on the ClientHello SNI | `sni=api.github.com`, bytes, duration — `method=- path=- code=0` |
| `api.partner-bank.test` | 80 `protocol: HTTP` → `targetPort: 443` | terminated, then re-originated as mutual TLS from a `DestinationRule` with `tls.mode: MUTUAL` and `credentialName: partner-bank-client` | `method=POST path=/transfers code=200`, `sni=-` |

So the pod speaks **plaintext** to the waypoint, the waypoint presents a client
certificate that exists only as `Secret partner-bank-client` in this namespace,
and the grant can be one method and one path rather than one host. A team
namespace never holds the credential — `kubectl -n team-b-batch get secret`
shows none — and a path is auditable only where the waypoint terminates. That
difference, not a preference, is the reason to ask sec-ops for an `HTTP` port
with a `MUTUAL` `DestinationRule` when a partner's calls must be audited per
call. The allow-list side of it is
[`repos/team-sec-ops/README.md`](../../team-sec-ops/README.md); the simulation
the demo calls is [`sim/partner-bank/`](../../../sim/partner-bank/README.md).

## Why a waypoint is an egress gateway

In ambient mode ztunnel routes traffic to a service's waypoint *before*
forwarding it to the destination, and a `ServiceEntry` is a service. So a
`ServiceEntry` attached to this waypoint makes every mesh call to that external
host traverse this one proxy, with no `VirtualService`, no `HTTPRoute` and no
`DestinationRule` — the five objects sidecar mode needs for the same result.
See [Egress gateways](https://istio.io/latest/docs/ambient/usage/egress-gateway/).

## The cross-namespace half

Istio's own walkthrough keeps the `ServiceEntry` in the waypoint's namespace and
enrolls that namespace with `istio.io/use-waypoint`. This project splits the two,
because the waypoint is platform property and the allow-list is sec-ops property.
Cross-namespace waypoint use needs both
halves, and a mistake in either fails as *no route*, not as an error:

1. **On the Gateway, here.** The `mesh` listener carries
   `allowedRoutes.namespaces.from: Selector` matching
   `platform.k8s-base/role: egress-allowlist`. Without it the waypoint is usable
   only from `platform-egress` itself. Istio documents this as the required
   gateway-side configuration for cross-namespace use (available since 1.23).
2. **On each `ServiceEntry`, in the sec-ops repo.** `istio.io/use-waypoint:
   egress-waypoint` *and* `istio.io/use-waypoint-namespace: platform-egress`.
   The first label alone resolves inside the `ServiceEntry`'s own namespace,
   finds nothing, and the call leaves the mesh unproxied — where the team
   baseline `NetworkPolicy` drops it.

The selector is deliberately a role label rather than
`kubernetes.io/metadata.name: egress-allowlist`: the namespace is stamped by the
`ResourceSet`, and the label is what makes "the allow-list namespace" a role the
platform admits rather than a name the platform hardcodes.

`istio.io/dataplane-mode: ambient` on `egress-allowlist` is **not** required.
Ambient enrollment governs pods, and that namespace holds none — the
`ServiceEntry` needs only the two waypoint labels. The team template stamps
the ambient label on every workload namespace anyway, where it is a no-op.

## `platform-egress-to-world` is an allow, not a deny

Read the file's own comment first. The cluster-wide object is additive: it grants
`platform-egress` pods egress to the `world` entity and to kube-dns. The *only*
in "only the waypoint may reach the internet" is enforced one layer up, by the
per-namespace team baseline having no `0.0.0.0/0` egress rule since round two
(§2.3). Round one's `ipBlock: 0.0.0.0/0` is what this epic removes.

Expressing it as an `egressDeny` on everything-but-`platform-egress` was
rejected: in Cilium deny beats allow with no ordering, so a cluster-scoped deny
whose selector is one label wrong takes the platform's own image pulls offline
with it, and no later allow can reopen the path
(`repos/infra/network/base/README.md`).

## What a team pod actually does

```
team-b-batch/egress-probe
  └─ DNS: api.github.com ──▶ ztunnel DNS proxy (in-pod, on by default since 1.25)
       └─ answer: a 240.240.0.0/16 auto-allocated VIP for the ServiceEntry
  └─ connect VIP:443 ──▶ ztunnel ──HBONE/mTLS──▶ egress-waypoint:15008
                                                   │ AuthorizationPolicy: is team-b-batch granted?
                                                   └─▶ TLS passthrough by SNI ──▶ api.github.com:443
```

Cilium sees only `team-b-batch → platform-egress:15008`, which the team
baseline allows. The VIP never reaches the wire. A host with no `ServiceEntry`
resolves through the DNS proxy to its real address, ztunnel has no waypoint for
it, and the call is dropped by the caller's own baseline — which is why
`demo-egress` expects a Hubble `DROPPED`, not a 403 from the waypoint, for
`example.com`.

## Validation without a cluster

```sh
kustomize build repos/platform/egress/base
kubeconform -strict -ignore-missing-schemas repos/platform/egress/base/*.yaml
```

Both `Gateway` (Gateway API v1.6.0 experimental, vendored by H1 in
`repos/infra/crds/base/gateway-api/`) and `CiliumClusterwideNetworkPolicy` need
`-ignore-missing-schemas`.
