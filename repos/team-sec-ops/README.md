# team-sec-ops — the edge repo

`team-sec-ops` is a team like any other: its own repo, its own cosign key, its
own Flux objects, reconciled under impersonation. What makes it different is what lives in its
namespaces — the three edges of the cluster:

| Namespace | Contents | Epic |
| --- | --- | --- |
| `egress-allowlist` | one `ServiceEntry` + `AuthorizationPolicy` pair per external host a team may call, plus a `DestinationRule` where the waypoint originates the TLS | H3, X3 |
| `public-api` | the `HTTPRoute`s the public Gateway accepts — one path prefix per team on the one public host — and the edge policies teams cannot weaken, one `SecurityPolicy` per auth class | H4, X0, X1 |
| `partner-api` | one directory per business partner: the route the partner Gateway accepts, its API-key policy and its rate limit — plus, from the environment's `envs/<env>/`, the roster that says which of them are onboarded here and their key Secrets | X2, P1 |

Each edge's `base/kustomization.yaml` sets its own `namespace:` — they are three
namespaces of one team, so there is no repo-level `namespace` and none in
`clusters/`. `edges/public-api/` has its own
[`README.md`](edges/public-api/README.md) with the four-party model and the
route review checklist, and `edges/partner-api/` has
[its own](edges/partner-api/README.md) with the partner onboarding checklist;
the rest of this file is the part that is the same for every edge.

## Layout: the contract in `base/`, the roster in `envs/<env>/`

Each edge is a **unit**: `edges/<edge>/base/` is what is the same everywhere,
and `edges/<edge>/envs/<env>/` is what that environment adds. The split is not
because of hostnames — those are already `${CLUSTER_DOMAIN}` variables. It is
because the **roster** is per environment: which partners are onboarded and
which external hosts are allow-listed, and in what shape. That adds and removes
objects, which a variable cannot do.

```
repos/team-sec-ops/
├── kustomization.yaml          resources: [clusters/local]  — the repo check; Flux reads the path below
├── clusters/local/
│   └── kustomization.yaml     the roster of units: one line per edges/<edge>/envs/local, nothing else
└── edges/
    ├── public-api/
    │   ├── base/              the whole public edge: routes/, policies/, its own root
    │   └── envs/local/        ../../base and nothing more — the public edge is the same everywhere
    ├── partner-api/
    │   ├── base/              partners/<partner>/{route,security,ratelimit}.yaml; its root is `resources: []`
    │   └── envs/local/        the roster, and one <partner>-keys.enc.yaml per onboarded partner
    └── egress-allowlist/
        ├── base/              the hosts that are the same in every environment
        └── envs/local/        ../../base plus the hosts whose object shape is this environment's
```

The Flux `Kustomization` the fleet repo stamps for this team reads
`path: ./clusters/local`. The repo's root `kustomization.yaml` renders the same
directory, so `kustomize build repos/team-sec-ops` is still the whole repo and
is byte-identical to what Flux applies. `clusters/local/kustomization.yaml` is
a roster and nothing else: no `namespace`, no patches — those belong to the
unit.

**`edges/partner-api/base/kustomization.yaml` is deliberately `resources: []`.**
A real root there would be a second answer to "which partners exist", and the
answer is the `envs/<env>/` roster and nothing else; the empty root exists only
so that every unit's `base/` builds, and it renders nothing. Everything else
that is a root builds on its own — each edge's `base/` and `envs/local/`, each
`edges/partner-api/base/partners/<partner>`, and `clusters/local`.

**No `namePrefix`, `nameSuffix` or generators anywhere under this repo.** Five
references inside it are by object name — the two Envoy Gateway policies'
`targetRefs` → `HTTPRoute <partner>`, `credentialRefs` → `Secret
<partner>-keys`, the `AuthorizationPolicy` `targetRefs` → `ServiceEntry
api-partner-bank-test`, and the `DestinationRule` `credentialName` → `Secret
partner-bank-client` — and kustomize has no name-reference configuration for
Envoy Gateway or Istio CRDs. A rename rewrites none of them, and four of the
five then fail *silently*: an unattached `SecurityPolicy` is an open route.

## The signature is the approval

Teams do not get write RBAC here, and they do not get the key. A team opens a
**pull request** against this repo; sec-ops reviews it and ships it with
`make push REPO=team-sec-ops`, which signs the artifact with
`.keys/cosign/team-sec-ops/cosign.key`. The `OCIRepository` verifies against the
sec-ops public key alone, so a team that edits this repo locally and pushes it
cannot have it reconciled:

```sh
make push REPO=team-sec-ops SIGN_AS=team-a   # SourceVerified=False
```

That is the whole enforcement model. There is no second mechanism — no admission
policy standing in for review, no RBAC exception for "urgent" hosts. Review,
signature, reconcile.

## What the cluster proved about the ownership split

The one thing this model depended on and could not be verified off-cluster:
**does istiod push an `AuthorizationPolicy` from this namespace to a waypoint in
`platform-egress`?** It does. The waypoint's listener configuration carries
`ns[egress-allowlist]-policy[api-github-com]-rule[0]`, and the grants behave:
`api.github.com` from `team-b-batch` returns 200, and from `team-a-apps` — which
is not named in that policy, although the host *is* on the list — the connection
is accepted and closed (`curl: (35) TLS connect error: unexpected eof`) and the
waypoint's `tcp.rbac.denied` counter increments. So sec-ops keeps both halves:
the list **and** who may use it. Nothing had to move to the platform.

Four consequences worth stating, all measured:

- **An unlisted host never reaches the waypoint at all.** A waypoint is only on
  the path of traffic a `ServiceEntry` steers to it, so `example.com` is dialled
  directly by the pod and dies on the pod's own baseline `NetworkPolicy` as a
  Cilium `EGRESS DENIED`. There is no configuration that makes an unlisted host
  produce a waypoint denial — which means **the only denial this namespace
  authors is the listed-but-not-granted one.**
- **The audit trail is the waypoint's access log, and it needs two mesh
  settings.** Istio ships with access logging off; `meshConfig.accessLogFile`
  turns it on, and `meshConfig.accessLogFormat` with
  `%FILTER_STATE(io.istio.peer_principal:PLAIN)%` is what names the caller
  (`%DOWNSTREAM_PEER_URI_SAN%` is empty on a waypoint). A granted passthrough
  call logs `caller=spiffe://cluster.local/ns/team-b-batch/sa/default
  sni=api.github.com method=- path=- code=0 …` — the identity and the host, and
  for a `protocol: TLS` entry never the path. The `method=`, `path=` and `code=`
  fields were added in X3 and carry real values only where the waypoint
  terminates, which is the next bullet.
- **A path is only auditable where the waypoint terminates.** `api.github.com`
  is `protocol: TLS`, so its log line carries the SNI host and nothing finer; a
  grant on it cannot say "only `POST /transfers`" because the waypoint never
  sees a request line. `api.partner-bank.test` is `protocol: HTTP` with the TLS
  originated at the waypoint, and the same log line carries the method and the
  path. That difference, not a preference, is why a partner whose calls must be
  audited per call gets a `DestinationRule`.
- **A waypoint reads a `credentialName` Secret only if its ServiceAccount may
  list Secrets in its own namespace.** istiod runs a SubjectAccessReview on the
  proxy's behalf and, denied, leaves the credential `WARMING` with no error on
  any Istio object — the handshake then never happens. `platform-egress` carries
  a namespace-scoped `Role`/`RoleBinding` (`egress-waypoint-credentials`) for the
  waypoint's ServiceAccount, and it is the platform's to maintain, not this
  namespace's.

## Egress: one file per external host

`egress-allowlist/<host-with-dashes>.yaml` — `api.github.com` becomes
`api-github-com.yaml`, and the `ServiceEntry` and the `AuthorizationPolicy`
inside it carry that same name. One host, one file, one name, so a PR diff is
legible and `git log -- edges/egress-allowlist/base/api-github-com.yaml` is that
host's complete grant history.

**Which directory the file goes in** is the one judgement the split asks for:

> an entry lives in `edges/egress-allowlist/base/` when the host, its resolution
> and its callers are the same in every environment, and in
> `edges/egress-allowlist/envs/<env>/` otherwise.

`api.github.com` and `httpbin.org` are public hosts resolved by DNS, called by
the same namespaces everywhere — base. `api.partner-bank.test` is none of those
things: on `local` it is the `sim/partner-bank` container, so the entry is
`resolution: STATIC` with a pinned `172.28.0.250` endpoint and a port 80 `HTTP`
entry whose TLS the waypoint originates, while a real environment would name the
partner's real DNS name with `resolution: DNS` and **no `endpoints` field at
all** — and grant it to whichever team is onboarded there. That is three
differences in object shape and a fourth that names a team, which is why it is
not one object with one substituted string and why no `PARTNER_BANK_ENDPOINT`
variable exists.

Each file holds **two objects, plus a `DestinationRule` when the waypoint
originates the TLS** (`api-partner-bank-test.yaml` is the one such file today):

- a **`ServiceEntry`** with the host, port 443 `protocol: TLS`,
  `resolution: DNS`, and the two labels that attach it to the platform's
  waypoint in another namespace — `istio.io/use-waypoint: egress-waypoint` and
  `istio.io/use-waypoint-namespace: platform-egress`. `protocol: TLS` means the
  waypoint routes on the SNI value in the ClientHello and **passes the
  connection through without terminating it**: no certificate management at the
  edge, and no custom CA in any application pod.
- an **`AuthorizationPolicy`** whose `targetRefs` names that `ServiceEntry`,
  listing the namespaces (or principals) allowed to use it. `targetRefs` of kind
  `ServiceEntry` must be in the **same namespace** as the policy, which is why
  both objects live here rather than in `platform-egress`.
- optionally a **`DestinationRule`** naming the same host, with
  `trafficPolicy.tls.mode: MUTUAL`, a `credentialName` and an `sni`. This is
  what turns an `HTTP` port into a real outbound TLS session: the pod speaks
  plaintext to the waypoint, the waypoint presents a client certificate the
  partner issued and that lives only in `platform-egress`, and no team
  namespace ever holds the credential. The `DestinationRule` is the *only*
  object here that is not a grant — it is the platform's half of a bilateral
  partner relationship, reviewed in the same PR.

An ALLOW policy exists for every host, so anything not granted is denied: a team
that is not named in the rules gets no exit even though the host is on the list.

Current state:

| File | Host | Granted to | Shape |
| --- | --- | --- | --- |
| `edges/egress-allowlist/base/api-github-com.yaml` | `api.github.com` | `team-b-batch` | 443 TLS passthrough, L4 grant |
| `edges/egress-allowlist/base/httpbin-org.yaml` | `httpbin.org` | `team-a-apps` | 443 TLS passthrough, plus port 80 HTTP restricted to `GET /get` and `GET /status/*` |
| `edges/egress-allowlist/envs/local/api-partner-bank-test.yaml` | `api.partner-bank.test` | `team-b-batch/sa/payments` | port 80 HTTP → `targetPort: 443`, `resolution: STATIC`, waypoint-originated mutual TLS, `POST /transfers` only |

`httpbin.org`'s port 80 entry is the one place the waypoint sees plaintext HTTP
and can therefore enforce L7 — method and path. It exists to demonstrate that
the allow-list is not only "which host" but "which call", and it is the reason
to prefer a 443-only entry everywhere else: a TLS-passthrough grant is
**host-granular and nothing finer**.

## Review checklist

Before shipping a PR into `egress-allowlist/`:

1. **One file, one host.** Filename, `ServiceEntry` name,
   `AuthorizationPolicy` name — and the `DestinationRule` name, where there is
   one — all agree. A file never covers two hosts, and the only third object it
   may add is that `DestinationRule`.
   **And the right directory**: `edges/egress-allowlist/base/` when the host,
   its resolution and its callers are identical in every environment, and
   `edges/egress-allowlist/envs/<env>/` with a line in that environment's
   `kustomization.yaml` otherwise.
2. **`hosts` has no wildcard.** `*.example.com` disables the DNS proxy's address
   auto-allocation and makes the grant unbounded. Name the exact host.
3. **Port 443 `protocol: TLS` unless there is a stated reason.** An `HTTP` port
   means the waypoint sees plaintext; accept it only with method/path rules, and
   say in the PR why plaintext is acceptable to the requesting team. Plaintext
   *inside the cluster only* is the stated reason to prefer: an `HTTP` port with
   `targetPort: 443` and a `MUTUAL` `DestinationRule` is encrypted on the wire
   and auditable by path, which a passthrough entry can never be. For any
   partner whose calls must be auditable per call rather than per host, that is
   the shape to ask for.
4. **Both waypoint labels present and spelled right.** A missing
   `istio.io/use-waypoint-namespace` fails as *no route*, not as an error: the
   traffic quietly bypasses the waypoint and dies in the caller's
   `NetworkPolicy`, which reads like a network bug for the requesting team.
5. **The `AuthorizationPolicy` names the narrowest scope that works.** The
   requesting team's *workload* namespace, not its whole team; a
   `principals:` entry (`cluster.local/ns/<ns>/sa/<sa>`) rather than a namespace
   where the team has a dedicated ServiceAccount.
6. **`exportTo` is not a control here.** Ztunnel and waypoints ignore the field
   and read it as `*`, so every `ServiceEntry` in this namespace is visible
   cluster-wide. Visibility is not the grant — the `AuthorizationPolicy` is. Do
   not accept a PR that relies on `exportTo` for isolation.
7. **The requesting team is on the PR**, and the host is one their service
   genuinely calls. There is no expiry mechanism: what is merged stays until
   someone deletes it.
8. **A `credentialName` names a Secret in `platform-egress`, never here.** The
   waypoint reads it through SDS from its own namespace; a `credentialName`
   pointing at a Secret in `egress-allowlist` or in a team namespace silently
   fails the handshake. The Secret is `kubernetes.io/tls` with `tls.crt`,
   `tls.key` and `ca.crt`, and it is the platform's to create — `make
   partner-sim-inject` for the simulation, a SOPS Secret in the platform repo
   on a real cluster.

## Validation without a cluster

```sh
kustomize build repos/team-sec-ops            # the whole repo, through clusters/local
kustomize build repos/team-sec-ops/clusters/local   # what Flux applies — identical output
kubeconform -strict -ignore-missing-schemas $(find repos/team-sec-ops -name '*.yaml')
```

`ServiceEntry` and `AuthorizationPolicy` have no schema in kubeconform's default
bundle, so `-ignore-missing-schemas` is required and the real check is the
`kustomize build` plus review.

Every root in the repo builds on its own, which is what keeps a reviewer able to
render the piece a PR touches:

```sh
for d in repos/team-sec-ops repos/team-sec-ops/clusters/local \
         repos/team-sec-ops/edges/public-api/base \
         repos/team-sec-ops/edges/public-api/envs/local \
         repos/team-sec-ops/edges/partner-api/base \
         repos/team-sec-ops/edges/partner-api/envs/local \
         repos/team-sec-ops/edges/partner-api/base/partners/partner-a \
         repos/team-sec-ops/edges/partner-api/base/partners/partner-b \
         repos/team-sec-ops/edges/egress-allowlist/base \
         repos/team-sec-ops/edges/egress-allowlist/envs/local; do
  kustomize build $d >/dev/null && echo "ok $d"
done
```

`edges/partner-api/base` is in that list and renders nothing; that is the
correct result, not a check that failed. `edges/` itself and
`edges/partner-api/base/partners/` have no `kustomization.yaml` and are not
roots.

## Secrets

`.sops.yaml` is rendered by `scripts/teams.mk` from
`.keys/<env>/team-sec-ops/age.pub` (`make team-render-pubkeys`) once
`team-sec-ops` is in `TEAMS`; never hand-edit it. The rules in
`repos/team-c/README.md` apply unchanged — nothing in this repo is plaintext if
it is a Secret, and no private key is ever committed.

**Every `*.enc.yaml` lives under an `envs/<env>/`, never in a `base/`.** A key
Secret in `base/` would be one value shared by every environment, which is the
thing the split exists to prevent; and because the Flux `Kustomization` reads
`./clusters/local`, a stray `*.enc.yaml` at the repo root or in a `base/` is not
merely wrong, it is never built at all. The rendered `.sops.yaml` rule is a
catch-all `path_regex: .*\.enc\.yaml$`, so it matches the `envs/` path with no
change and `make team-sops-encrypt` needs none either — it `cd`s into
`repos/team-sec-ops` first:

```sh
make team-sops-encrypt TEAM=team-sec-ops \
  FILE=edges/partner-api/envs/local/partner-a-keys.enc.yaml
```

`decryption` sits on the one `Kustomization` the fleet stamps for this team, so
**one mis-encrypted file fails all three edges at once**, not just
`partner-api`. That is an argument for checking the recipient before pushing,
not for splitting the Kustomization.
