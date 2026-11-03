What: no manifests — `demo-egress` is driven entirely by objects that already
live in the repos (`repos/platform/egress/base/`,
`repos/team-sec-ops/edges/egress-allowlist/{base,envs/local}/`, `repos/team-b/batch/egress-probe/base/`). There is
nothing to push and nothing to attach, so this directory holds no
`kustomization.yaml`.
Attached to: nothing.
Expected: see below.

---

# `demo-egress` — whitelisted outbound only

**Claim.** No team pod has a route to the internet. The only exit is the Istio
egress waypoint in `platform-egress`, it only carries hosts `team-sec-ops` has
put on the allow-list, it only carries them for the teams the matching
`AuthorizationPolicy` names, and it writes an access log that says who called.
Everything else dies in Cilium on the sending side.

**Cast.**

| Object | Where | Role |
| --- | --- | --- |
| `Gateway egress-waypoint` | `platform-egress` | the single exit, platform-owned, `istio.io/waypoint-for: service` |
| `ServiceEntry`/`AuthorizationPolicy api-github-com` | `egress-allowlist` | the allow-list entry, sec-ops-owned, grants `team-b-batch` |
| `ServiceEntry`/`AuthorizationPolicy httpbin-org` | `egress-allowlist` | grants `team-a-apps` only — the control for a team-scoped grant |
| `CiliumClusterwideNetworkPolicy platform-egress-to-world` | cluster | the only pods allowed to reach `world` |
| `NetworkPolicy team-baseline-default-deny` | every team namespace | no `0.0.0.0/0` since round two: this is the "no route" half |
| `Job egress-probe` | `team-b-batch` | the three probes |

## The three verdicts

```sh
kubectl -n team-b-batch delete job egress-probe --ignore-not-found
flux -n team-b reconcile kustomization team-b --with-source
kubectl -n team-b-batch wait --for=condition=Complete job/egress-probe --timeout=120s
kubectl -n team-b-batch logs job/egress-probe
```

```
probe github=200
    body: Keep it logically awesome.

probe example=000
    curl: curl: (28) Operation timed out

probe directip=000
    curl: curl: (28) Operation timed out

results github=200 example=000 direct-ip=000
```

| Probe | What it is | Why that verdict |
| --- | --- | --- |
| `https://api.github.com/zen` | on the allow-list, granted to `team-b-batch` | ztunnel resolves it through the `ServiceEntry` and sends it over HBONE to the waypoint, which passes the TLS through by SNI. **200.** |
| `https://example.com/` | resolvable, but no `ServiceEntry` | ztunnel has no waypoint for the host, so the pod dials the real address directly — and the baseline has no rule for it. **Cilium drop on egress, curl exit 28.** |
| `--resolve example.com:443:93.184.215.14` | a literal address, no DNS at all | nothing to resolve, nothing to attach a waypoint to. **Cilium drop on egress, curl exit 28.** |

The second row is the one worth reading twice. The intuitive expectation is a
403 from the waypoint, as though the waypoint were a proxy that inspects every
request and refuses unknown hosts. It is not: a waypoint is only ever on the
path of traffic a `ServiceEntry` steers to it. An unlisted host therefore fails
*earlier* and *harder* — on the sending pod's own `NetworkPolicy`, before the
mesh is involved at all. Both the second and third probe produce the same Cilium
verdict; the only difference between them is that one did a DNS lookup first.

## The drop, from Cilium's side

```sh
cilium hubble port-forward &
hubble observe --verdict DROPPED --from-namespace team-b-batch --last 10
```

```
policy-verdict:none EGRESS DENIED (TCP Flags: SYN)
  team-b-batch/egress-probe-...:46210 (ID:nnnnn) <> 93.184.215.14:443 (world)
Policy denied DROPPED (TCP Flags: SYN)
```

`policy-verdict:none EGRESS DENIED` is the layer-1 wording from
`repos/infra/network/base/README.md`: the caller's own baseline has no rule matching
the destination. The successful github probe is *absent* from this output and
appears instead as a flow to `platform-egress` on 15008 — which is the point:

```sh
hubble observe --from-namespace team-b-batch --to-namespace platform-egress --last 10
# team-b-batch/egress-probe-... -> platform-egress/egress-waypoint-...:15008  FORWARDED
```

No flow from `team-b-batch` to `140.82.x.x` exists anywhere in Hubble. The team
pod never touched the internet; the waypoint did.

## The access log names the caller

```sh
kubectl -n platform-egress logs deploy/egress-waypoint --tail=20 | grep team-b-batch
```

Two things had to be turned on for that line to exist, both in
`repos/platform/istio/base/istiod.yaml`. Istio ships with access logging **off**
(`meshConfig.accessLogFile: /dev/stdout`), and Envoy's default format carries the
SNI host but **not** the caller: on a waypoint `%DOWNSTREAM_PEER_URI_SAN%` is
empty. The operator that works is `%FILTER_STATE(io.istio.peer_principal:PLAIN)%`,
set through `meshConfig.accessLogFormat`. (A `Telemetry` object with a custom
`extensionProviders` entry was tried first and never took effect on the
waypoint's TCP listener.) The line then reads:

```
[2026-11-02T11:21:58.294Z] caller=spiffe://cluster.local/ns/team-b-batch/sa/default \
  sni=api.github.com upstream=20.205.243.168:443 route=inbound-vip|443|tcp|api.github.com; \
  flags=- sent=4381 received=813 duration=247
```

That is the audit property the whole design is for: outbound traffic is
attributable to a team, not to a NAT address. For a TLS-passthrough entry the
log line carries the SNI host and the byte counts, **not** the path — the
waypoint never decrypts. `api.github.com/zen` is not in the log; `api.github.com`
is.

## The grant is per team, not per cluster

`httpbin.org` is on the allow-list, and `api.github.com` is on the allow-list.
Neither is open to everyone:

```sh
# team-a may reach httpbin.org and must not reach api.github.com
kubectl -n team-a-apps exec deploy/podinfo -- \
  curl -sS -m 10 -o /dev/null -w 'httpbin=%{http_code}\n' https://httpbin.org/get
# httpbin=200
kubectl -n team-a-apps exec deploy/podinfo -- \
  curl -sS -m 10 -o /dev/null -w 'github=%{http_code}\n' https://api.github.com/zen
# github=000  curl: (35) TLS connect error: unexpected eof while reading
```

Both calls reach the waypoint, because both hosts have a `ServiceEntry` and both
`ServiceEntry`s attach to it. The second one is refused *there*, by
`AuthorizationPolicy api-github-com`, which names `team-b-batch` and not
`team-a-apps`. This is the one case in the demo where the verdict really is the
waypoint's, and it looks different from a Cilium drop: the TCP connection is
**accepted and then closed**, so curl fails inside the TLS handshake with exit
35 rather than timing out, Hubble shows the flow to `platform-egress:15008` as
FORWARDED, and the waypoint counts it:

```sh
kubectl -n platform-egress exec deploy/egress-waypoint -c istio-proxy -- \
  pilot-agent request GET stats | grep '^tcp.rbac'
# tcp.rbac.allowed: 2
# tcp.rbac.denied: 1
```

A denial inside the mesh is visible to the mesh and invisible to Cilium. That
counter is also the proof of the thing this design depended on and could not be
checked off-cluster: **istiod does push an `AuthorizationPolicy` from
`egress-allowlist` to a waypoint in `platform-egress`**, so `team-sec-ops` keeps
both the allow-list and the per-team grants. The waypoint's listener config
names the policy directly:

```sh
istioctl proxy-config listener deploy/egress-waypoint -n platform-egress -o json \
  | grep -o 'ns\[egress-allowlist\]-policy\[[^]]*\]-rule\[[0-9]*\]' | sort -u
# ns[egress-allowlist]-policy[api-github-com]-rule[0]
# ns[egress-allowlist]-policy[httpbin-org]-rule[0]
# ns[egress-allowlist]-policy[httpbin-org]-rule[1]
```

`httpbin.org`'s port 80 entry additionally restricts the *call*: plaintext HTTP
is where the waypoint can see methods and paths.

```sh
kubectl -n team-a-apps exec deploy/podinfo -- \
  curl -sS -m 10 -o /dev/null -w 'get=%{http_code}\n' http://httpbin.org/get      # 200
kubectl -n team-a-apps exec deploy/podinfo -- \
  curl -sS -m 10 -o /dev/null -w 'post=%{http_code}\n' -X POST http://httpbin.org/post
# post=403   — L7 authorization at the waypoint
```

Over 443 the same grant is host-granular and nothing finer, because
`protocol: TLS` means passthrough. That asymmetry is the argument for keeping
egress entries on 443 and treating the port 80 entry as a demonstration.

## Cleanup

```sh
kubectl -n team-b-batch delete job egress-probe --ignore-not-found
```

Flux re-creates it on the next reconcile, which is also how the demo re-runs it.
