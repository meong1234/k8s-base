# `public-api` — the company's public edge

Everything the internet can reach goes through an `HTTPRoute` in this namespace.
`team-sec-ops` owns the namespace; this repo is pushed as the OCI artifact
`team-sec-ops:local`, signed with the sec-ops cosign key, and reconciled into
`public-api` by that team's `flux` ServiceAccount.

Four parties must agree before a service is public, and removing any one of them
takes it offline:

| Party | Object | Where |
| --- | --- | --- |
| platform | `Gateway public`, whose single HTTPS listener admits routes only from namespaces labelled `platform.k8s-base/role: public-edge` | `repos/platform/ingress/base/` |
| team-sec-ops | the `HTTPRoute` in `public-api`, plus the edge policies below | this unit, `repos/team-sec-ops/edges/public-api/base/` |
| platform (again) | the path prefix the route claims, allocated in the fleet repo's `teams.yaml` (`apiPaths`) and rendered into `ConfigMap flux-system/api-paths-<team>` | `repos/fleet/clusters/local/` |
| the owning team | a `ReferenceGrant` naming the Service the route targets | `repos/<team>/<ns>/public-consent.yaml` |

Without the `ReferenceGrant` the route reports `ResolvedRefs: False` and the edge
serves 500. Without the route there is no hostname. Without the label on this
namespace the Gateway refuses the route altogether.

## This whole edge is in `base/`

Every edge in `repos/team-sec-ops/` is a unit, `base/` + `envs/<env>/`, and the
public edge is entirely in `base/`: it is the same in every environment.
`envs/local/kustomization.yaml` is the trivial `resources: [../../base]` and
nothing more. There is no roster here and
nothing per-environment — one public host, and each team's API a path prefix on
it that the platform allocated in `teams-inputs.yaml`. The route set *does*
differ between environments in the sense that a team may not exist on all of
them, but that is not expressed by an overlay: a route whose backend is absent
reports `ResolvedRefs: False` and the edge serves a 503, which is a louder
signal than a route that quietly is not there. Reviewing an environment's
`teams-inputs.yaml` against `base/routes/` is the control, not a per-env patch.

`base/` is a root and builds alone, and so is `envs/local/`. The repo's roster
(`repos/team-sec-ops/clusters/local/kustomization.yaml`) names `envs/local`,
and the Flux `Kustomization` reads that roster.

`${CLUSTER_DOMAIN}` and `${PUBLIC_PORT}` in this directory and below are Flux
post-build variables, not strings a reviewer invents: the `Kustomization` the
fleet repo stamps for this team substitutes them from `ConfigMap
flux-system/cluster-vars`, where the environment declares its own zone and
browser-facing port. On `local` they resolve to
`local-dev.test` and `8443`. The prefix in front of the zone — `api.`, `dex.`,
`*.` — is a platform convention and stays literal in the manifest.

## What is in here

| Path | Object | Note |
| --- | --- | --- |
| `base/routes/team-a-podinfo.yaml` | `HTTPRoute team-a-podinfo` | `api.${CLUSTER_DOMAIN}/podinfo` → `podinfo` in `team-a-apps`, `auth: none`; arrived as a PR from team-a |
| `base/routes/team-a-catalog.yaml` | `HTTPRoute team-a-catalog` | `api.${CLUSTER_DOMAIN}/catalog` → the same Service, `auth: jwt` |
| `base/routes/team-b-orders.yaml` | `HTTPRoute team-b-orders` | `api.${CLUSTER_DOMAIN}/orders` → `podinfo` in `team-b-apps`, `auth: jwt` |
| `base/routes/platform-dex.yaml` | `HTTPRoute platform-dex` | `dex.${CLUSTER_DOMAIN}` → `dex` in `platform-identity`; arrived as a PR from the platform team. `platform-identity` is the one namespace in `publicBackendNamespaces` |
| `base/routes/https-redirect.yaml` | `HTTPRoute https-redirect` | the `http` listener's only route: 301 to `https` on `${PUBLIC_PORT}`. No backend, so `public-route-owner` lets it keep the `*.${CLUSTER_DOMAIN}` wildcard |
| `base/policies/ratelimit.yaml` | `BackendTrafficPolicy public-edge` | local rate limit, 20 requests per minute per distinct client IP, with `xRateLimitHeaders: DraftVersion03` |
| `base/policies/security-none.yaml` | `SecurityPolicy public-edge-none` | CORS, on the routes labelled `platform.k8s-base/auth: none` |
| `base/policies/security-jwt.yaml` | `SecurityPolicy public-edge-jwt` | the same CORS block plus the Dex JWT provider (`aud: public-api`, JWKS fetched from `platform-identity/dex:5556`, `email` and `groups` forwarded as `x-user-email` and `x-user-groups`), on the routes labelled `platform.k8s-base/auth: jwt` |

All three policies attach by `targetSelectors`. The rate limit selects
`platform.k8s-base/public-route: "true"` alone, which `base/kustomization.yaml`
stamps on every object, so it covers every public route
whatever its class. The two `SecurityPolicy` objects select that label **plus**
`platform.k8s-base/auth`, one per class: Gateway API allows only one policy of a
kind per target, so one CORS-and-JWT policy over every route is not expressible
and the `auth` label is what partitions them. A new route is therefore rate
limited, CORS-fenced and in exactly one auth class the moment it is merged —
there is no "forgot the policy" state, no route in both classes, and a team
cannot weaken any of the three because a team cannot write in this namespace.
The CORS block is duplicated between the two files; that is the price of
per-class selection, and it is cheaper than a merge mechanism this API version
may not honour.

Envoy Gateway policies are *local*: `targetRefs` has no `namespace` field, so a
policy here cannot name `platform-ingress/public` directly. Selecting this
namespace's routes is the same guarantee one level down. Gateway API also allows
only one policy of a kind per target.

**The security response headers are a route filter, not a policy.** The first
version put them in the `BackendTrafficPolicy` as a `responseOverride` with only
a `header` block, which is the only Gateway-scoped response-header writer the
v1.9 API has — and on a running proxy it **replaces the response body with an
empty one and drops `Content-Type`**: a 200 came back with `size=0`. They are a
`ResponseHeaderModifier` filter on each route now. Still sec-ops-owned, still
unweakenable by a team, one attachment level further down; the cost is that a new
route needs the filter copied in, so it is the first item on the checklist.

## The real flow

In a company repo this directory is behind CODEOWNERS:

```
/edges/public-api/base/routes/   @company/sec-ops
/edges/public-api/base/policies/ @company/sec-ops
```

1. The owning team opens a PR adding one file under `base/routes/`, and a second PR
   against its own repo adding the `ReferenceGrant`.
2. Sec-ops reviews against the checklist below and merges. CI pushes and signs
   the artifact with the sec-ops key.
3. Flux reconciles. The route only resolves once the team's own PR has merged
   too.

Locally the PR is simulated by editing `base/` and running
`make push REPO=team-sec-ops`. The signature **is** the approval: a team that
edits this repo on its laptop and runs `make push REPO=team-sec-ops SIGN_AS=team-a`
produces an artifact the `team-sec-ops` `OCIRepository` refuses with
`SourceVerified: False`, because it is pinned to the sec-ops public key.

## Review checklist

Before merging a file under `base/routes/`:

- [ ] **Owner label.** `metadata.labels['platform.k8s-base/owner-team']` names the
      team that owns the backend. `public-route-owner` denies a route without it.
- [ ] **Hostname is `api.${CLUSTER_DOMAIN}`.** There is one public host and every
      team API is a path prefix on it. A single-label hostname
      (`dex.${CLUSTER_DOMAIN}`) is only acceptable for a platform backend, and
      `*.${CLUSTER_DOMAIN}` only for a route that has no backend and only redirects
      — `public-route-owner` enforces both.
- [ ] **Path prefix belongs to the owner.** The first segment of every
      `PathPrefix` — and every rule must have one — is a prefix the platform
      allocated to the owner team in the fleet repo's `teams.yaml` (`apiPaths`).
      `api-path-owner` denies anything else, including an `Exact` path and a rule
      with no `matches`. Check the allocation, not the PR's word:
      `kubectl -n flux-system get cm -l platform.k8s-base/registry=api-paths -o yaml`.
      A new prefix is a PR against the fleet repo, reviewed by the platform team.
- [ ] **Prefix is stripped.** A `URLRewrite` filter with
      `ReplacePrefixMatch: /` so the backend serves its own paths and does not
      have to know its public prefix.
- [ ] **Auth class declared.** `metadata.labels['platform.k8s-base/auth']` is
      `none` for an open API or `jwt` for one behind a Dex token.
      `public-route-owner` denies a route without it, and the label is what
      selects the `SecurityPolicy` — a route cannot end up with no class.
      `api-key` belongs to the partner edge and is denied here.
      `none` gets `base/policies/security-none.yaml` (CORS only). `jwt` gets
      `base/policies/security-jwt.yaml`: every request must carry
      `Authorization: Bearer <id_token>` issued by Dex for the **`public-api`**
      client, or the edge answers 401 before the backend is consulted. A token
      for any other client — a developer's `kubernetes` kubelogin token included
      — is refused as well, because the provider pins `audiences: [public-api]`;
      that one is a **403**, not a 401, because Envoy verified the signature and
      then rejected the audience.
      The verified `email` and `groups` claims arrive at the backend as
      `x-user-email` and `x-user-groups`, so a secured API reads its caller from
      a header and never parses a token. Dex's local connector emits no `groups`
      claim for a static password, so on this cluster only `x-user-email`
      arrives; a missing claim is an omitted header, not a 401. Mint one for the
      demo users with
      `make api-token USER=carol@team-b.local PASS=carol-local-dev`
      (`make login-help` lists the passwords); it is valid for 10 minutes.
      Changing a merged route's class moves it between the two policies with no
      other edit, which is the point of the label.
- [ ] **Backend belongs to the owner.** Every `backendRefs` namespace is the owner
      team's, or one of the namespaces the platform opened for public backends
      (`platform-identity`, for Dex). Reserved prefixes — `platform-`, `flux-`,
      `kube-`, `istio-`, `cert-manager`, `envoy-gateway-`
      — are denied by admission even with the right label.
- [ ] **Consent exists.** A `ReferenceGrant` in the backend namespace names this
      namespace as `from` and that Service as `to`. Check the team's PR, not
      their word:
      `kubectl -n <backend-ns> get referencegrant -o yaml`.
- [ ] **Policies cover it.** The route carries
      `platform.k8s-base/public-route: "true"` (the kustomization stamps it — do
      not override `metadata.labels` in a way that drops it) so both edge
      policies select it.
- [ ] **parentRef is the `public` Gateway with `sectionName: https`.** A route
      without a `sectionName` also attaches to the `http` listener and would be
      served in plaintext.
- [ ] **No path or header rewrite that widens the backend.** A public route
      exposes exactly the paths the PR describes.

## Validation without a cluster

```sh
kustomize build repos/team-sec-ops/edges/public-api/base
kustomize build repos/team-sec-ops/edges/public-api/envs/local   # identical output
kubeconform -ignore-missing-schemas $(find repos/team-sec-ops/edges/public-api -name '*.yaml')
```
