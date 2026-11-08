# Network and mesh

> **Who this is for.** Anyone who will debug "my pod cannot reach X", and
> anyone reviewing a network or authorization policy.
> **Afterwards you can** explain why there are two systems and what each
> decides, read a Hubble line and say which layer refused the call and which
> team can lift it, and explain why every policy on this cluster names port
> 15008.

## Two systems, two questions

Traffic between pods on this cluster is governed by two independent systems.
Both have to say yes.

**Cilium** is the CNI, the thing that gives pods a network at all. It also
enforces `NetworkPolicy`: rules about which pods may send packets to which,
decided by namespace and labels. When Cilium says no, the packet is dropped
and nothing on the other side ever sees it. Its observability tool, Hubble,
records every flow with a verdict, which makes Cilium the layer you can
*see*.

**Istio in ambient mode** is the service mesh. An agent on every node,
ztunnel, transparently wraps each pod-to-pod connection in mutual TLS, with
each side proving who it is with a certificate that encodes its namespace
and service account. Where a namespace needs rules about HTTP methods and
paths, a small Envoy proxy called a waypoint sits in front of the Service.
When the mesh says no, the connection is accepted and then refused: an HTTP
403 at a waypoint, or a reset from ztunnel.

The split in one line: Cilium decides whether *this namespace* may talk to
*that one*. Istio decides whether *this identity* may make *this call*.

## Why everything is port 15008

This is the fact that makes every network policy on the cluster readable,
so it is worth a careful paragraph.

When a pod in `team-b-apps` opens a connection to `podinfo.team-a-apps:9898`,
ztunnel intercepts it before it leaves the pod's network namespace. It
re-sends the connection as HBONE, an HTTP CONNECT tunnel, to the
destination's ztunnel on port **15008**. The original destination port, 9898,
travels inside the tunnel. Cilium, sitting below, sees a connection to
port 15008 and nothing else.

```
   pod in team-b-apps                                              pod in team-a-apps
   curl podinfo.team-a-apps:9898                                   podinfo listening on 9898
         │ intercepted before it leaves the pod                          ▲ delivered inside the tunnel
         ▼                                                               │
      ztunnel (node 1) ══════ HBONE: mTLS, port 15008 ══════▶ ztunnel (node 2)
         ▲                                                               ▲
         │   what Cilium sees:   team-b-apps/podinfo ──▶ team-a-apps/podinfo:15008
         │   what Cilium never sees: port 9898
         └── so every cross-namespace NetworkPolicy names 15008, and the app port is enforced by the mesh
```

Consequently a `NetworkPolicy` that allows port 9898 across namespaces
matches nothing, and every policy here that admits cross-namespace traffic
names 15008. The application port, or the method and path, is enforced by
the mesh inside the tunnel, where it is visible.

`demo-mtls` shows this directly: a Job calls across two namespaces six
times, every packet Cilium records is on 15008, and ztunnel logs the two
SPIFFE identities with `dst.hbone_addr=<pod ip>:9898` as the inner address.

The one exception is kubelet health probes. They arrive in plaintext on the
application port, from a link-local address the CNI assigns, and they are
outside the mesh on purpose. A separate allow rule exists only for that
address.

## The ingress gateways in an ambient mesh

The three doors (`public`, `internal`, `partner`) are Istio-managed Gateway
API `Gateway`s in `platform-ingress`, rendered by istiod into one Envoy
Deployment each, the same way a waypoint is. Two facts about them explain
every policy that names them:

- **They are not captured by ztunnel.** `platform-ingress` is deliberately
  not labelled ambient. A gateway terminates TLS itself, so the plaintext
  TCP that k3s' servicelb forwards into it never meets ztunnel's inbound and
  the mesh-wide STRICT rule has nothing to say about it. Labelling the
  namespace would capture the gateways and break the door.
- **They speak HBONE outbound anyway.** istiod tells the gateway's Envoy which
  endpoints are ambient, and it tunnels to them on 15008 with its own
  identity, `spiffe://cluster.local/ns/platform-ingress/sa/public-istio`.
  That is why the team baseline admits `platform-ingress` on 15008 and
  nothing else, and why a team's `AuthorizationPolicy` can name the gateway
  as a source like any other workload.

One port-level exception exists for their sake: istiod fetches the Dex JWKS
that the public edge verifies tokens against, and istiod is not a mesh
workload, so Dex's port 5556 is `PERMISSIVE` for plaintext while the rest of
Dex stays `STRICT`. The platform's own `edge-authz` pod in `platform-ingress`
is enrolled individually, by a pod label, so the partner gateway reaches it
over HBONE.

## The baseline every team gets

When the fleet template stamps a workload namespace, it stamps one
`NetworkPolicy` named `team-baseline-default-deny`. Read it once and most
network questions answer themselves. It allows:

```
                          ┌────────────── team-b-apps ──────────────┐
   same team (any ns) ───▶│                                         │───▶ same team (any ns)
   allowFrom namespaces ─▶│    NetworkPolicy                        │───▶ kube-dns :53
   ingress gateways:15008▶│    team-baseline-default-deny           │───▶ platform-egress :15008
   probe address ────────▶│                                         │
                          │    anything else, either direction:     │ ✗   other teams, the internet,
                          │    DROPPED                               │     flux-system, istio-system
                          └─────────────────────────────────────────┘
   a team may add rules (a depends-on, an allow); an admission policy stops it deleting this one
```

**Ingress from**
- the team's own namespaces (matched by the `platform.k8s-base/team` label)
- any namespace the fleet input lists under `allowFrom`
- `platform-ingress`, the ingress gateways' namespace, on 15008, so a public route can reach the Service
- the probe address, so health checks work

**Egress to**
- the team's own namespaces
- kube-dns on port 53
- `platform-egress` on 15008, so outbound calls can reach the egress waypoint

Everything else, in both directions, is dropped. There is no rule to the
internet; that is why the egress waypoint is the only way out.

A team holds `admin` in its workload namespaces, so a team *can* add its own
network policies, and does when it declares a cross-team dependency. A team
*cannot* delete or edit the baseline: an admission policy refuses any write
to an object named `team-baseline-*` by anyone except the platform's own
identities. A human cluster-admin is deliberately not on that list.

Alongside the network policy sits an `AuthorizationPolicy` with the same
baseline name that allows the team's own namespaces at the mesh layer. It
exists so a team's calls to itself are never hostage to what it has
written for other teams.

Two cluster-wide Cilium policies in `repos/infra/network/base/` sit above
all of that: DNS is reachable from everywhere, and no team pod may reach
`flux-system` or `istio-system`. They are the platform's and no team RBAC
can touch them.

## Reading a drop

When a call fails, Hubble and curl between them tell you which layer refused
it and therefore which team can fix it. Learn these four patterns and most
"network bugs" become five-minute conversations.

| What you see | Which layer | What it means | Who can lift it |
| --- | --- | --- | --- |
| Hubble: `policy-verdict:none EGRESS DENIED … :15008`; curl exits 56 after ~10s | the **caller's** baseline | nobody declared this destination; the caller's own policy has no matching rule | the caller ships a depends-on, and the owner ships an allow |
| Hubble: `Policy denied by denylist` | the cluster-wide deny | a team pod tried to reach a platform namespace | nobody; it is the one deny the platform keeps |
| HTTP `403` with body `RBAC: access denied`; curl exits 0 | the **owner's** waypoint | the namespace was admitted, but the identity, method or path is not in the owner's allow | the owner widens the allow |
| TLS error `unexpected eof`; curl exits 35 | the egress waypoint | the external host is listed but this team is not granted | sec-ops adds the team to the grant |

Two timing details that have cost people afternoons:

- Give curl more than ten seconds. ztunnel owns the socket and waits out its
  tunnel deadline before resetting, so a client timeout under ten seconds
  reports a timeout (28) instead of the reset (56), and you lose the signal.
  The demos use `-m12`.
- Cilium regenerates endpoint policy some seconds after a change. A probe
  run immediately after applying or deleting a policy can succeed for the
  wrong reason. The demos wait for it; `demos/_cilium-settle.sh` is the
  helper.

## Cross-team traffic is two files

Nothing flows between two teams unless both wrote it down. The owning team
ships an *allow*: one file with an ingress `NetworkPolicy` on 15008 and an
`AuthorizationPolicy` naming one service account, one method and one path.
The calling team ships a *depends-on*: one file with an egress
`NetworkPolicy` on 15008. Both come from templates in
`repos/platform/components/`, both are rendered into plain YAML in the
team's own repo where a reviewer can read them as a diff, and either team
deleting its file closes the path.

The allow's `NetworkPolicy` selects the owner's **waypoint** pods, not the
service's pods, when the namespace has a waypoint. The caller's traffic
enters the waypoint, and the waypoint re-originates the connection to the
pod as the namespace's own identity, which the baseline already admits.

One check to make before trusting a cross-team setup that works: the
owner's Service must carry the label `istio.io/use-waypoint`. Without it the
`AuthorizationPolicy` is accepted by the API server and never consulted, and
every method on every path returns 200. It is the single most common way
for this to be "working" while enforcing nothing.

## Waypoints

A waypoint is an Envoy proxy the platform stamps into a team's workload
namespace when the fleet input says `waypoint: true`. A Service that carries
the label above routes through it, and that is where L7 rules run: "team-b's
`orders` service account may `GET /api/info` and nothing else" is a waypoint
rule. team-a has a waypoint, which is why team-b's access to team-a's
podinfo can be that narrow. A namespace without one can still allow a
caller, but only by port.

The platform also runs one waypoint in `platform-egress` that is the only
way out of the cluster. Every `ServiceEntry` the security team writes points
at it, so every outbound call traverses that one proxy. That one has its
own section on [edges](09-edges.md).

## Things measured on this stack that are not bugs

Three behaviours were measured during integration and are documented so
nobody re-debugs them:

- Cilium's DNS proxy cannot deliver answers to the client on Docker
  Desktop's kernel, so there is no L7 DNS rule and Hubble shows no `DNS
  Query` lines. Flows to kube-dns are still visible at L4 and DNS works.
- Kubelet probes reach pods carrying the `world` identity rather than
  `host`, so a cluster-wide allow for probes exists in the network unit's
  `envs/local/` and
  a second one for the address istio-cni rewrites probes to. Without them
  every pod with a default-deny policy fails its own readiness probe.
- Flux's own default-deny network policy is turned off, because the probe
  behaviour above would crash-loop all seventeen Flux controllers and leave
  nothing to reconcile the fix.

Each has its measurement, the alternatives that were tried, and the blast
radius in `repos/infra/network/base/README.md`.

## Useful commands

```sh
make hubble-port-forward
hubble observe --verdict DROPPED --from-namespace team-b-apps --last 10
hubble observe --from-namespace team-b-apps --to-namespace team-a-apps --last 10

make ztunnel-workloads        # HBONE in the protocol column means the pod is in the mesh
make waypoint-status
istioctl ztunnel-config policies
kubectl -n team-a-apps get networkpolicy,authorizationpolicy
```

## Where the detail lives

- The baseline, the two cluster-wide policies, the removed per-team deny and why, with measured Hubble output: `repos/infra/network/base/README.md`
- The two cross-team templates, every placeholder, and the variant for a namespace without a waypoint: `repos/platform/components/allow-team/README.md`, `repos/platform/components/depends-on-service/README.md`
- A cross-team demo walked step by step with real output: `demos/cross-team-access/README.md`
