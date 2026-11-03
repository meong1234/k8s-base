What: no manifests — `demo-cross-team-access` is driven entirely by objects that
already live in the team repos (`repos/team-a/apps/podinfo/base/allow/`,
`repos/team-b/apps/orders/base/{orders-serviceaccount,caller}.yaml`,
`repos/team-b/apps/orders/base/depends-on/`). There is nothing to push and nothing to
attach, so this directory holds no `kustomization.yaml`.
Attached to: nothing.
Expected: see below.

---

# `demo-cross-team-access` — a cross-team call takes both halves, one identity and one route

**Claim.** `team-b` can call `podinfo.team-a-apps:9898` only because both halves
exist in git: team-a's `allow-team-b-podinfo` and team-b's
`depends-on-team-a-podinfo`. Remove either half and the call stops. The allow
names **one ServiceAccount** and **one route**, so the same call from a pod in
the *same namespace* under a *different* ServiceAccount stops too, and so does a
method or path team-a did not allow. Call a team that was never declared and
Cilium drops the packet before the mesh sees it.

**Cast.**

| Object | Where | Role |
| --- | --- | --- |
| `ServiceAccount orders` | `team-b-apps` | the named calling identity, `cluster.local/ns/team-b-apps/sa/orders` |
| `Deployment caller` | `team-b-apps` | curl pod running **as** `orders` |
| `Deployment caller-other` | `team-b-apps` | curl pod running as `default` — same namespace, wrong identity |
| `NetworkPolicy` + `AuthorizationPolicy allow-team-b-podinfo` | `team-a-apps` | the owning team's half, one file |
| `Gateway waypoint` | `team-a-apps` | the Envoy the `AuthorizationPolicy` runs in |
| `Service podinfo`, labelled `istio.io/use-waypoint: waypoint` | `team-a-apps` | what puts the waypoint in path |
| `NetworkPolicy depends-on-team-a-podinfo` | `team-b-apps` | the calling team's half |

## Step 0 — the two halves, in two repos

```sh
cat repos/team-a/apps/podinfo/base/allow/team-b-podinfo.yaml
cat repos/team-b/apps/orders/base/depends-on/team-a-podinfo.yaml
kubectl -n team-a-apps get networkpolicy,authorizationpolicy
kubectl -n team-b-apps get networkpolicy,serviceaccount orders
kubectl -n team-a-apps get service podinfo -o jsonpath='{.metadata.labels}'
kubectl -n team-a-apps get gateway waypoint
```

Expected: `allow-team-b-podinfo` of both kinds in `team-a-apps`,
`depends-on-team-a-podinfo` in `team-b-apps`, `serviceaccount/orders`, and both
halves written against **port 15008** — never 9898.

```
NAME                                                     POD-SELECTOR
networkpolicy.../allow-team-b-podinfo                    gateway.networking.k8s.io/gateway-name=waypoint
networkpolicy.../team-baseline-default-deny            <none>
networkpolicy.../team-baseline-waypoint-control-plane  gateway.networking.k8s.io/gateway-name=waypoint

NAME                                                   ACTION
authorizationpolicy.../allow-team-b-podinfo            ALLOW
authorizationpolicy.../team-baseline-allow-same-team ALLOW

NAME       CLASS            ADDRESS         PROGRAMMED
waypoint   istio-waypoint   10.43.199.121   True
```

The Service label is the thing to check first if this demo ever appears to pass
too easily: **without `istio.io/use-waypoint` the `AuthorizationPolicy` is
accepted by the API server and never consulted, and every path returns 200.**

Note what the `NetworkPolicy` selects: the **waypoint** pods, not podinfo's.
team-a's traffic enters the waypoint, which re-originates the connection to
podinfo as `cluster.local/ns/team-a-apps/sa/waypoint` — a same-namespace hop the
baseline `AuthorizationPolicy` admits.

## Step 1 — take both halves away

```sh
flux -n team-a suspend kustomization team-a
flux -n team-b suspend kustomization team-b
kubectl -n team-a-apps delete networkpolicy allow-team-b-podinfo
kubectl -n team-a-apps delete authorizationpolicy allow-team-b-podinfo
kubectl -n team-b-apps delete networkpolicy depends-on-team-a-podinfo
```

Both Kustomizations are suspended first, or Flux puts the objects straight back.

## Step 2 — without the allow, Cilium drops it

```sh
kubectl -n team-b-apps exec deploy/caller -- \
  curl -m12 -sS -o /dev/null -w 'no-allow=%{http_code}\n' http://podinfo.team-a-apps:9898/api/info
hubble observe --verdict DROPPED --from-namespace team-b-apps --to-namespace team-a-apps --last 5
```

```
no-allow=000
curl: (56) Recv failure: Connection reset by peer
command terminated with exit code 56

team-b-apps/caller-…:54516 (ID:26951) <> team-a-apps/waypoint-…:15008 (ID:12334) policy-verdict:none EGRESS DENIED (TCP Flags: SYN)
team-b-apps/caller-…:54516 (ID:26951) <> team-a-apps/waypoint-…:15008 (ID:12334) Policy denied DROPPED (TCP Flags: SYN)
```

Three things in that output matter. The destination port is **15008**, not 9898:
ztunnel rewrote it before Cilium saw the packet, which is why a policy written
against the service port matches nothing. The verdict is **EGRESS** DENIED — the
*caller's* own baseline is the first thing in the way, before team-a's ingress
rule is ever reached. And `curl` exits **56**, not 28: the caller's own ztunnel
owns the socket, waits out its 10-second HBONE deadline and resets, so a client
timeout shorter than 10s hides the reset entirely (hence `-m12`).

## Step 3 — put both halves back

```sh
flux -n team-a resume kustomization team-a && flux -n team-a reconcile kustomization team-a --with-source
flux -n team-b resume kustomization team-b && flux -n team-b reconcile kustomization team-b --with-source
```

Wait for `allow-team-b-podinfo` and `depends-on-team-a-podinfo` to reappear, then
give Cilium a moment: a probe run within ~30 seconds of a policy change can
succeed regardless of policy because the endpoints' policy has not been
regenerated yet. `demos/_cilium-settle.sh` is what the demo uses.

## Step 4 — the declared call, on the declared route

```sh
kubectl -n team-b-apps exec deploy/caller -- \
  curl -m12 -s -o /dev/null -w 'allowed=%{http_code}\n' http://podinfo.team-a-apps:9898/api/info
hubble observe --from-namespace team-b-apps --to-namespace team-a-apps --last 5
istioctl ztunnel-config policies -o json | grep -c allow-team-b-podinfo
```

```
allowed=200
```

Hubble still only ever shows `:15008`. There is no flow to `:9898` between the
two namespaces in the whole capture — the only app-port lines anywhere come from
`169.254.7.127`, which is istio-cni's SNAT address for kubelet probes.

## Step 5 — a route the owning team did not allow

The allow lists `methods: ["GET"]` and `paths: ["/api/info"]` and nothing else.

```sh
kubectl -n team-b-apps exec deploy/caller -- \
  curl -m12 -s -X POST -d hello -w ' | POST-api-echo=%{http_code}\n' http://podinfo.team-a-apps:9898/api/echo
kubectl -n team-b-apps exec deploy/caller -- \
  curl -m12 -s -w ' | GET-healthz=%{http_code}\n' http://podinfo.team-a-apps:9898/healthz
```

```
RBAC: access denied | POST-api-echo=403
RBAC: access denied | GET-healthz=403
```

`/api/echo` is a real podinfo endpoint that answers 200 to a POST from inside
team-a, so the 403 is the rule and not a 404. `/healthz` is the clearer case: a
route that exists, that the caller's identity is otherwise allowed to reach, and
that this allow simply does not name.

## Step 6 — the same namespace, the wrong identity

```sh
kubectl -n team-b-apps exec deploy/caller-other -- \
  curl -m12 -sS -w ' | wrong-identity=%{http_code}\n' http://podinfo.team-a-apps:9898/api/info
```

```
RBAC: access denied | wrong-identity=403
```

**It is an HTTP 403, not a TCP reset, and `curl` exits 0.** This was the open
question H2 could not answer off-cluster, and the answer is unambiguous: once
the Service carries `istio.io/use-waypoint`, team-b's connection terminates at
the waypoint, the waypoint's `targetRefs` rule is evaluated, and the waypoint
answers the request itself. ztunnel never makes the decision — it logs
`handling RBAC delete team-a-apps/allow-team-b-podinfo` for exactly that reason,
because a `targetRefs` policy belongs to the waypoint and not to ztunnel.

So while the waypoint is in path, the `NetworkPolicy` half is what refuses an
*undeclared namespace* (step 2) and the `AuthorizationPolicy` is what refuses an
undeclared *identity or route* (steps 5 and 6). The `NetworkPolicy` is still the
fence if the Service label is ever dropped, and it is what Hubble can see.

## Step 7 — the control: a team nobody declared

```sh
kubectl -n team-b-apps exec deploy/caller -- \
  curl -m12 -sS -o /dev/null -w 'team-c=%{http_code}\n' http://podinfo.team-c-apps:9898/
hubble observe --verdict DROPPED --from-namespace team-b-apps --to-namespace team-c-apps --last 5
```

```
team-c=000
command terminated with exit code 56

team-b-apps/caller-…:54516 (ID:26951) <> team-c-apps/podinfo-…:15008 (ID:12334) policy-verdict:none EGRESS DENIED (TCP Flags: SYN)
team-b-apps/caller-…:54516 (ID:26951) <> team-c-apps/podinfo-…:15008 (ID:12334) Policy denied DROPPED (TCP Flags: SYN)
```

team-c never wrote anything and nobody wrote anything about team-c. That is the
steady state for every pair of namespaces in the cluster; the paragraphs above
describe the single exception somebody declared.

## Step 8 — the owning team is not narrowed by a rule it wrote for someone else

```sh
kubectl -n team-a-apps exec deploy/podinfo -- \
  curl -m12 -s -o /dev/null -w 'same-team-POST=%{http_code}\n' -X POST -d hi http://podinfo.team-a-apps:9898/api/echo
```

```
same-team-POST=200
```

The allow is an ALLOW rule scoped to team-b's principal. team-a's own traffic
matches the baseline `team-baseline-allow-same-team` instead, which is why
`POST /api/echo` still works for its owner.

## Cleanup

`make demo-cross-team-access-cleanup` resumes both Kustomizations
unconditionally and reconciles the allow back, then prints both namespaces'
policies. It runs automatically as part of `make demo-all`. If the demo is
interrupted between steps 1 and 3, that target is the recovery — and it is worth
running, because a suspended `Kustomization` is the one state in this suite that
does not heal itself.
