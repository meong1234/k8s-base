# Edges

> **Who this is for.** Anyone publishing an API, calling a partner or an
> external service, or reviewing a sec-ops pull request.
> **Afterwards you can** say which of the three edges a request belongs to,
> list every object on its path with its owner, and explain why the security
> team is a tenant with a signing key rather than a role with permissions.

## Three doors, one reviewer

The cluster's boundary has three doors. Two face in, one faces out.

| Door | Direction | Hostname and port | Namespace |
| --- | --- | --- | --- |
| public | in | `api.local-dev.test:8443` (plus `dex.` and an HTTP redirect) | `public-api` |
| partner | in | `<partner>.partners.local-dev.test:9443` | `partner-api` |
| egress | out | one listed host per file | `egress-allowlist` |

```
                                  ┌────────────────────────────────────────────┐
   public users ────8443────────▶ │ Gateway public   ──▶ public-api  (routes)   │──▶ team Services
   partners ────────9443────────▶ │ Gateway partner  ──▶ partner-api (routes)   │──▶ (with the owner's
   engineers ───────8443────────▶ │ Gateway internal ──▶ Hubble UI, behind OIDC │     ReferenceGrant)
                                  │                                            │
   listed hosts ◀─────────────────│ egress-waypoint  ◀── egress-allowlist      │◀── team pods
   (only, and logged)             │                      (one file per host)   │
                                  └────────────────────────────────────────────┘
                                   the boxes are the platform's (repos/platform)
                                   what is routed through them is sec-ops's (repos/team-sec-ops)
```

The doors themselves are the platform's: the Gateway objects, the proxies
istiod renders from them, the certificates, the egress waypoint, all in
`repos/platform/`. What passes through them is the security team's: the
routes, the edge policies, the partner contracts, the host list, all in
`repos/team-sec-ops/`. The platform owns the door; sec-ops owns the rules on
it and the list of what goes through.

## Why sec-ops is a team, not a role

The obvious design is to give a security group write permission on the
gateway namespaces. This platform does something different and it is worth
understanding why.

`team-sec-ops` is onboarded exactly like a product team: its own
repository, its own cosign key, its own age key, its own Flux source and
Kustomization reconciling as `system:serviceaccount:team-sec-ops:flux`,
bound in its own three namespaces plus one scoped `Role` in
`platform-ingress` for the three Istio policy kinds that can only attach to
a Gateway from the Gateway's own namespace. The only thing that makes its
namespaces special is a role label the fleet input gives them
(`public-edge`, `partner-edge`, `egress-allowlist`), and the platform's
Gateways and admission policies key on that label.

So the enforcement model is the same one every team already lives with.
Product teams do not get write access to the edge namespaces and they do
not get the key. A team that wants a public route opens a pull request
against the sec-ops repo. Sec-ops reviews it against a checklist, merges,
and pushes. The push signs the artifact with the sec-ops key, the Flux
source verifies against that key alone, and the route goes live. A team
that clones the sec-ops repo and pushes it from their own laptop produces
an artifact signed with the wrong key, and the source reports
`SourceVerified: False`. `demo-exposure` does exactly that.

There is no other mechanism: no admission policy standing in for the
review, no RBAC exception for urgent hosts, no "platform applies it for
you". Review, signature, reconcile. Because the review is a pull request,
it has a diff, a reviewer's name and a history.

## The public door

One public hostname, and every team's API is a path prefix on it:
`/podinfo` and `/catalog` are team-a's, `/orders` is team-b's. For a route
in `public-api` to be accepted and to work, four owners contribute, and
each contribution is a file someone can point at:

| Owner | Object | What it does |
| --- | --- | --- |
| platform | `Gateway public` in `platform-ingress` | terminates TLS; admits routes only from a namespace labelled `public-edge` |
| platform | `apiPaths` in the fleet input, rendered to a ConfigMap | allocates the prefix to the team |
| sec-ops | the `HTTPRoute` in `public-api` | names the host, the prefix, the backend, the owner and the auth class |
| the owning team | a `ReferenceGrant` in its namespace | consents to routes from `public-api` targeting its Service |

Two admission policies make the route honest. `public-route-owner` requires
the owner label, requires an auth class of `none` or `jwt`, requires every
backend to be in the owner's namespaces, and requires the hostname to be
the public host. `api-path-owner` requires every rule to be a `PathPrefix`
whose first segment is allocated to the owner, and forbids any route from
claiming a prefix allocated to someone else. The messages tell you which
check failed and what the allocation is.

### Authentication at the edge

Istio attaches edge policy to the Gateway, not to a route, and only from the
Gateway's own namespace. So the three objects that govern the public door are
sec-ops files applied into `platform-ingress`, under a Role scoped to exactly
these three kinds:

| Object | What it does |
| --- | --- |
| `RequestAuthentication public-edge-jwt` | validates any `Authorization: Bearer` token against Dex, audience pinned to the `public-api` client, and writes the verified `email` and `groups` claims to `x-user-email` and `x-user-groups` |
| `AuthorizationPolicy public-edge-require-jwt` | `DENY` without a verified token on `api.<zone>`, except the prefixes listed in `notPaths`, which are the open ones |
| `EnvoyFilter public-edge-ratelimit` | 20 requests per minute per client address, across the whole door |

The policy is fail-closed: a new prefix on the public host is secured the
moment its route is merged, and opening it is an edit to `notPaths` that a
reviewer reads next to the route's `auth: none` label. Rate limiting is
Gateway-wide, so it covers a route before anyone thinks about it. CORS is the
one thing that moved onto the route, as a Gateway API `CORS` filter, and
admission refuses a public route that reaches a backend without one. A team
cannot weaken any of this because a team cannot write in `platform-ingress`.

A `jwt` route answers:

- **403** `RBAC: access denied` to a request with no token. Authorization
  refused it: there was no credential to check.
- **401** to a token the edge cannot verify: malformed, expired, or signed
  by someone other than Dex. Authentication refused it.
- **403** to a token that verifies but was issued for a different audience.
  A developer's own `kubectl` login token is the common case: Dex signed it,
  but for the `kubernetes` client. The edge says so in
  `www-authenticate: … error="invalid_token"`, which the no-token 403 does
  not carry: a verified credential presented at the wrong door is a
  permission problem, and the JWT filter codes it as one.
- **200** to a token for `public-api`, and the backend receives
  `x-user-email` with the verified claim. The backend authorises on a header
  it can trust and never parses a JWT itself. A client cannot pre-set that
  header: the first filter on the door strips `x-user-email` and
  `x-user-groups` from every request before the JWT filter writes them.

`make api-token USER=<email> PASS=<password>` mints one for the demo users.

### Two routes that are not on `api.`

The Dex login page at `dex.<zone>` and the HTTP-to-HTTPS redirect are both
served from `public-api` and both break the "one host" rule. They are
admitted by two narrow escapes in the policy rather than by name: a
single-label hostname is allowed only when the owner is `platform` and every
backend is in a namespace the platform explicitly opened for public backends
(`platform-identity`), and the zone wildcard is allowed only on a route with
no backend at all whose only filter is a redirect. Both are measured in the
policies README.

## The partner door

A business partner is not a public user and should not share the public
door. A partner gets a second gateway on its own port, 9443, with its own
proxy Deployment and its own wildcard certificate for `*.partners.<zone>`. A
partner's flood or misconfiguration lands on the partner proxy only and can
never shadow a path on the public host.

```
   partner-a ──x-api-key: …──▶ :9443  partner-a.partners.<zone>/v1/orders
                                  │  Gateway partner (own proxy, own certificate)
                                  ├─ AuthorizationPolicy partner-edge-api-key ──▶ edge-authz: is the key in Secret partner-a-keys?
                                  │     (CUSTOM, the platform's)                  yes ──▶ x-partner-id: partner-a-prod   no ──▶ 401
                                  ├─ EnvoyFilter partner-a-ratelimit              100 requests/min per client, this hostname only
                                  └─ HTTPRoute partner-a ──▶ podinfo in team-b-apps   (ReferenceGrant lists partner-api)
                                        strips x-api-key                       backend sees x-partner-id, never the key

   edges/partner-api/base/partners/partner-a/   the contract: route, ratelimit             (same everywhere)
   edges/partner-api/envs/<env>/                the roster line + partner-a-keys.enc.yaml   (exists here or not)
```

Each partner is a directory under `edges/partner-api/base/partners/<name>/`
holding two objects named after the partner: the `HTTPRoute` for exactly one
hostname, `<name>.partners.<zone>`, which also strips `x-api-key` before the
backend; and an `EnvoyFilter` with that partner's contractual rate limit,
scoped to that hostname. The key check itself is one platform object on the
Gateway. Every request on the partner door is sent to `edge-authz`, a small
service in `platform-ingress` that reads `Secret <name>-keys` for the
hostname's first label, compares the presented key against every entry, and
answers 200 with the entry's name as `x-partner-id`, or 401. Istio has no
API-key primitive of its own; `tools/edge-authz/` is forty lines of decision
and a Secret watch, and the key Secrets, their format and their rotation are
exactly what they were.

Whether a partner *exists* in an environment is a separate question from
what its contract says, and the repo keeps them apart. The contract is in
the edge's `base/`, the same everywhere. The edge's `envs/<env>/` holds a
roster, one `resources:` line per onboarded partner, and beside it one
encrypted key file per partner. A partner live on `uat` and not yet on
`prod` is one roster line present in one `envs/` and absent in the other. An offline
check refuses a roster line without a key file and a key file without a
roster line.

Admission keeps the two doors apart: `api-key` is refused on the public
edge, `none` and `jwt` are refused on the partner edge, and a partner route
must have exactly one hostname in the partner subzone so two partners can
never share a key set. The owning team's consent is the same
`ReferenceGrant` as for the public door, with `partner-api` added as a
second `from`.

One rule specific to this repo: nothing may be renamed by kustomize, and no
`namespace:` transformer sits above the edge policies. The rate limit matches
the virtual host istiod names `<hostname>:9443`, edge-authz finds the Secret
by the hostname's first label, and a policy whose namespace was rewritten
attaches to nothing. None of these errors: a mis-scoped rate limit limits
nothing, and a rewritten policy is accepted by the API server and ignored by
the Gateway. A repo check refuses `namePrefix`, `nameSuffix` and the
generators anywhere under `repos/team-sec-ops`, and
`istioctl proxy-config route deploy/partner-istio -n platform-ingress` shows
what the proxy actually holds.

## The egress door

No pod has a route to the internet. The baseline network policy allows the
team's own namespaces, DNS, and one more destination: the egress waypoint in
`platform-egress`, on 15008. Everything that leaves the cluster goes through
that one proxy.

The allow-list is one file per external host in `egress-allowlist`, named
after the host with dots as dashes. Each file holds two objects with the
same name: a `ServiceEntry` that declares the host and carries the two
labels that steer it to the platform's waypoint, and an `AuthorizationPolicy`
that names which namespaces or service accounts may use it. Because an
allow policy exists for every host, a team not named on a host is refused
even though the host is listed.

Three shapes of entry exist today, and the difference between them is what
can be audited:

| Host | Shape | Granted to | The log can say |
| --- | --- | --- | --- |
| `api.github.com` | 443, TLS passed through by server name | `team-b-batch` | the host and byte counts, never the path |
| `httpbin.org` | 443 as above, plus a port 80 HTTP entry allowing `GET /get` and `GET /status/*` | `team-a-apps` | on port 80, the method and path |
| `api.partner-bank.test` | port 80 from the pod, terminated at the waypoint and re-originated as mutual TLS from a certificate only the waypoint holds | one service account, `POST /transfers` only | the method, the path, and the partner's log shows the platform's client certificate |

The third shape is the one to ask for when a partner's calls must be
auditable per call rather than per host, or when the partner demands a
client certificate. The team's pod speaks plaintext to the waypoint, the
certificate lives as a Secret in `platform-egress` and nowhere else, and
`kubectl -n team-b-batch get secret` shows a team has nothing it could
present. The simulation of such a partner is `sim/partner-bank/`, an nginx
container outside the cluster that answers `400` to anyone without the
certificate.

### How a refusal looks, and why it matters

Two refusals look deliberately different, and the difference tells a team
which side to ask:

- A host that is **not on the list** never reaches the waypoint. A waypoint
  is only on the path of traffic a `ServiceEntry` steers to it, so the pod
  dials the real address and its own baseline drops the packet. curl times
  out (28), Hubble shows `EGRESS DENIED`. Ask for the host.
- A host that is **listed but not granted** reaches the waypoint, which
  accepts the connection and closes it. curl fails inside the TLS handshake
  (35), Hubble shows the flow to `platform-egress` as forwarded, and the
  waypoint's `tcp.rbac.denied` counter goes up. Ask to be added to the grant.

The access log is the property the whole door exists for. It is configured
to print the caller's SPIFFE identity, so an outbound call reads:

```
caller=spiffe://cluster.local/ns/team-b-batch/sa/default sni=api.github.com upstream=20.205.243.168:443 …
```

Outbound traffic is attributable to a workload, not to a NAT address.

## Where the detail lives

- The egress review checklist, the base-versus-envs rule for a host, and what the cluster proved about cross-namespace policy: `repos/team-sec-ops/README.md`
- The public door, the four-party model, the route checklist, and why the security headers are a route filter: `repos/team-sec-ops/edges/public-api/README.md`
- The partner door and the onboarding checklist, including key rotation: `repos/team-sec-ops/edges/partner-api/README.md`
- The platform half of the edges, what is in `platform-ingress` and why the Istio policies are a second Flux stage: `repos/platform/edge-policies/README.md`
- The API-key authorizer, its contract with Envoy and why it watches Secrets rather than mounting them: `tools/edge-authz/README.md`
- The waypoint, its credential permission, and the silent `WARMING` state when it is missing: `repos/platform/egress/base/README.md`
- The partner simulation and why it runs outside the cluster: `sim/partner-bank/README.md`
